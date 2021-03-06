#
# Copyright (C) 2011 - 2014 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# @API Enrollments
#
# API for creating and viewing course enrollments
#
# @object Enrollment
#     {
#       // The unique identifier for the enrollment.
#       "id": 1,
#
#       // The unique identifier for the course.
#       "course_id": 1,
#
#       // The unique identifier for the section.
#       "course_section_id": 1,
#
#       // The current state of the enrollment.
#       "enrollment_state": "active",
#
#       // User can only access his or her own course section.
#       "limit_privileges_to_course_section": true,
#
#       // The unique identifier for the account.
#       "root_account_id": 1,
#
#       // The type of the enrollment.
#       "type": "StudentEnrollment",
#
#       // The enrollment role, for course-level permissions.
#       "role": "StudentEnrollment",
#
#       // The unique identifier for the user.
#       "user_id": 1,
#
#       // The date and time the enrollment was last updated, in ISO8601 format.
#       "updated_at": "2012-04-18T23:08:51Z",
#
#       // The date and time the enrollment was created, in ISO8601 format.
#       "created_at": "2012-04-18T23:08:51Z",
#
#       // The last activity date and time of the user for the enrollment, in ISO8601 format.
#       "last_activity_at": "2012-04-24T08:08:12Z",
#
#       // The URL to the Canvas web UI page for this course enrollment.
#       "html_url": "https://...",
#
#       // The grade information for the enrollment, if this is a student enrollment.
#       "grades": {
#
#         // The URL to the Canvas web UI page for the user's grades.
#         "html_url": "https://...",
#
#         // The user's current score in the course. Only included if user has permissions to view this grade.
#         "current_score": null,
#
#         // The user's final score in the course. Only included if user has permissions to view this grade.
#         "final_score": 0,
#
#         // The user's current grade in the course. Only included if user has permissions to view this grade.
#         "current_grade": null,
#
#         // The user's final grade in the course. Only included if user has permissions to view this grade.
#         "final_grade": null
#       },
#
#         // The user object for the enrollment.
#       "user": {
#
#         // The unique id of the user.
#         "id": 1,
#
#         // The unique login of the user.
#         "login_id": "bieberfever@example.com",
#
#         // The name of the user.
#         "name": "Justin Bieber",
#
#         // The short name of the user.
#         "short_name": "Justin B.",
#
#         // The sortable name of the user.
#         "sortable_name": "Bieber, Justin"
#       }
#     }
#
class EnrollmentsApiController < ApplicationController
  before_filter :get_course_from_section, :require_context

  @@errors = {
    :missing_parameters => 'No parameters given',
    :missing_user_id    => "Can't create an enrollment without a user. Include enrollment[user_id] to create an enrollment",
    :bad_type           => 'Invalid type',
    :bad_role           => 'Invalid role',
    :inactive_role      => 'Cannot create an enrollment with this role because it is inactive.',
    :base_type_mismatch => 'The specified type must match the base type for the role',
    :concluded_course   => 'Can\'t add an enrollment to a concluded course.'

  }

  include Api::V1::User
  # @API List enrollments
  # Depending on the URL given, return either (1) all of the enrollments in
  # a course, (2) all of the enrollments in a section or (3) all of a user's
  # enrollments. This includes student, teacher, TA, and observer enrollments.
  #
  # If a user has multiple enrollments in a context (e.g. as a teacher
  # and a student or in multiple course sections), each enrollment will be
  # listed separately.
  #
  # note: Currently, only an admin user can return other users' enrollments. A
  # user can, however, return his/her own enrollments.
  #
  # @argument type[] [String]
  #   A list of enrollment types to return. Accepted values are
  #   'StudentEnrollment', 'TeacherEnrollment', 'TaEnrollment',
  #   'DesignerEnrollment', and 'ObserverEnrollment.' If omitted, all enrollment
  #   types are returned. This argument is ignored if `role` is given.
  #
  # @argument role[] [String]
  #   A list of enrollment roles to return. Accepted values include course-level
  #   roles created by the {api:RoleOverridesController#add_role Add Role API}
  #   as well as the base enrollment types accepted by the `type` argument above.
  #
  # @argument state[] [String, "active"|"invited"|"creation_pending"|"deleted"|"rejected"|"completed"|"inactive"]
  #   Filter by enrollment state. If omitted, 'active' and 'invited' enrollments
  #   are returned.
  #
  # @returns [Enrollment]
  def index
    endpoint_scope = (@context.is_a?(Course) ? (@section.present? ? "section" : "course") : "user")

    return unless enrollments = @context.is_a?(Course) ?
      course_index_enrollments :
      user_index_enrollments

    enrollments = enrollments.joins(:user).select("enrollments.*").
      order("enrollments.type, #{User.sortable_name_order_by_clause("users")}")

    has_courses = enrollments.where_values.any? { |cond| cond.is_a?(String) && cond =~ /courses\./ }
    enrollments = enrollments.joins(:course) if has_courses

    enrollments = Api.paginate(
      enrollments,
      self, send("api_v1_#{endpoint_scope}_enrollments_url"))

    Enrollment.send(:preload_associations, enrollments, [:user, :course, :course_section])
    includes = [:user] + Array(params[:include])

    user_json_preloads(enrollments.map(&:user))
    render :json => enrollments.map { |e| enrollment_json(e, @current_user, session, includes) }
  end

  # @API Enroll a user
  # Create a new user enrollment for a course or section.
  #
  # @argument enrollment[user_id] [String]
  #   The ID of the user to be enrolled in the course.
  #
  # @argument enrollment[type] [String, "StudentEnrollment"|"TeacherEnrollment"|"TaEnrollment"|"ObserverEnrollment"|"DesignerEnrollment"]
  #   Enroll the user as a student, teacher, TA, observer, or designer. If no
  #   value is given, the type will be inferred by enrollment[role] if supplied,
  #   otherwise 'StudentEnrollment' will be used.
  #
  # @argument enrollment[role] [Optional, String]
  #   Assigns a custom course-level role to the user.
  #
  # @argument enrollment[enrollment_state] [Optional, String, "active"|"invited"]
  #   If set to 'active,' student will be immediately enrolled in the course.
  #   Otherwise they will be required to accept a course invitation. Default is
  #   'invited.'
  #
  # @argument enrollment[course_section_id] [Optional, Integer]
  #   The ID of the course section to enroll the student in. If the
  #   section-specific URL is used, this argument is redundant and will be
  #   ignored.
  #
  # @argument enrollment[limit_privileges_to_course_section] [Optional, Boolean]
  #   If a teacher or TA enrollment, teacher/TA will be restricted to the
  #   section given by course_section_id.
  #
  # @argument enrollment[notify] [Optional, Boolean]
  #   If true, a notification will be sent to the enrolled user.
  #   Notifications are not sent by default.
  #
  # @argument enrollment[self_enrollment_code] [Optional, String]
  #   If the current user is not allowed to manage enrollments in this
  #   course, but the course allows self-enrollment, the user can self-
  #   enroll as a student in the default section by passing in a valid
  #   code. When self-enrolling, the user_id must be 'self'. The
  #   enrollment_state will be set to 'active' and all other arguments
  #   will be ignored.
  #
  # @example_request
  #   curl https://<canvas>/api/v1/courses/:course_id/enrollments \
  #     -X POST \
  #     -F 'user_id=1' \
  #     -F 'type=StudentEnrollment' \
  #     -F 'enrollment_state=active' \
  #     -F 'course_section_id=1' \
  #     -F 'limit_privileges_to_course_section=true' \
  #     -F 'notify=false'
  #
  # @example_request
  #   curl https://<canvas>/api/v1/courses/:course_id/enrollments \
  #     -X POST \
  #     -F 'user_id=2' \
  #     -F 'type=StudentEnrollment'
  #
  # @returns Enrollment
  def create
    # error handling
    errors = []

    if params[:enrollment].blank?
      errors << @@errors[:missing_parameters] if params[:enrollment].blank?
    else
      return create_self_enrollment if params[:enrollment][:self_enrollment_code]

      role_name = params[:enrollment].delete(:role)
      type = params[:enrollment].delete(:type)
      if Enrollment.valid_type?(role_name)
        type = role_name
        role_name = nil
      end
      
      if role_name.present?
        params[:enrollment][:role_name] = role_name
        course_role = @context.account.get_course_role(role_name)
        if course_role.nil?
          errors << @@errors[:bad_role]
        elsif course_role.workflow_state != 'active'
          errors << @@errors[:inactive_role]
        else
          if type.blank?
            type = course_role.base_role_type
          elsif type != course_role.base_role_type
            errors << @@errors[:base_type_mismatch]
          end
        end
      end

      if type.present?
        errors << @@errors[:bad_type] unless Enrollment.valid_type?(type)
      else
        type = 'StudentEnrollment'
      end

      errors << @@errors[:missing_user_id] unless params[:enrollment][:user_id].present?
    end
    errors << @@errors[:concluded_course] if @context.completed? || @context.soft_concluded?
    return render_create_errors(errors) if errors.present?

    # create enrollment

    params[:enrollment][:no_notify] = true unless value_to_boolean(params[:enrollment][:notify])
    unless @current_user.can_create_enrollment_for?(@context, session, type)
      render_unauthorized_action && return
    end
    params[:enrollment][:course_section_id] = @section.id if @section.present?
    if params[:enrollment][:course_section_id].present?
      params[:enrollment][:section] = @context.course_sections.active.find params[:enrollment].delete(:course_section_id)
    end
    user = api_find(User, params[:enrollment].delete(:user_id))
    @enrollment = @context.enroll_user(user, type, params[:enrollment].merge(:allow_multiple_enrollments => true))
    @enrollment.valid? ?
      render(:json => enrollment_json(@enrollment, @current_user, session)) :
      render(:json => @enrollment.errors, :status => :bad_request)
  end

  def render_create_errors(errors)
    render json: {message: errors.join(', ')}, status: 403
  end

  def create_self_enrollment
    require_user

    options = params[:enrollment]
    code = options[:self_enrollment_code]
    # we don't just do a straight-up comparison of the code, since
    # plugins can override Account#self_enrollment_course_for to allow
    # for synthetic ones
    errors = []
    if @context != @context.root_account.self_enrollment_course_for(code)
      errors << "enrollment[self_enrollment_code] is invalid"
    end
    if options[:user_id] != 'self'
      errors << "enrollment[user_id] must be 'self' when self-enrolling"
    end
    return render_create_errors(errors) if errors.present?

    @current_user.validation_root_account = @domain_root_account
    @current_user.require_self_enrollment_code = true
    @current_user.self_enrollment_code = code
    if @current_user.save
      render(json: enrollment_json(@current_user.self_enrollment, @current_user, session))
    else
      render(json: {user: @current_user.errors}, status: :bad_request)
    end
  end

  # @API Conclude an enrollment
  # Delete or conclude an enrollment.
  #
  # @argument task [String, "conclude"|"delete"]
  #   The action to take on the enrollment.
  #
  # @example_request
  #   curl https://<canvas>/api/v1/courses/:course_id/enrollments/:enrollment_id \ 
  #     -X DELETE \ 
  #     -F 'task=conclude'
  #
  # @returns Enrollment
  def destroy
    @enrollment = @context.enrollments.find(params[:id])
    task = %w{conclude delete}.include?(params[:task]) ? params[:task] : 'conclude'

    unless @enrollment.send("can_be_#{task}d_by", @current_user, @context, session)
      return render_unauthorized_action
    end

    task = 'destroy' if task == 'delete'
    if @enrollment.send(task)
      render :json => enrollment_json(@enrollment, @current_user, session)
    else
      render :json => @enrollment.errors, :status => :bad_request
    end
  end

  protected
  # Internal: Collect course enrollments that @current_user has permissions to
  # read.
  #
  # Returns an ActiveRecord scope of enrollments on success, false on failure.
  def course_index_enrollments
    if authorized_action(@context, @current_user, [:read_roster, :view_all_grades, :manage_grades])
      scope = @context.enrollments_visible_to(@current_user, :type => :all, :include_priors => true).where(enrollment_index_conditions)
      unless params[:state].present?
        scope = scope.where("enrollments.workflow_state NOT IN ('rejected', 'completed', 'deleted', 'inactive')")
      end
      scope
    else
      false
    end
  end

  # Internal: Collect user enrollments that @current_user has permissions to
  # read.
  #
  # Returns an ActiveRecord scope of enrollments on success, false on failure.
  def user_index_enrollments
    user = api_find(User, params[:user_id])

    if user == @current_user
      # if user is requesting for themselves, just return all of their
      # enrollments without any extra checking.
      if params[:state].present?
        enrollments = user.enrollments.where(enrollment_index_conditions(true))
      else
        enrollments = user.current_and_invited_enrollments.where(enrollment_index_conditions)
      end
    else
      # otherwise check for read_roster rights on all of the requested
      # user's accounts
      approved_accounts = user.associated_root_accounts.inject([]) do |accounts, ra|
        accounts << ra.id if ra.grants_right?(@current_user, session, :read_roster)
        accounts
      end

      # if there aren't any ids in approved_accounts, then the user doesn't have
      # permissions.
      render_unauthorized_action and return false if approved_accounts.empty?

      enrollments = user.enrollments.where(enrollment_index_conditions).
        where(root_account_id: approved_accounts)

      # by default, return active and invited courses. don't use the existing
      # current_and_invited_enrollments scope because it won't return enrollments
      # on unpublished courses.
      enrollments = enrollments.where(workflow_state: %w{active invited}) unless params[:state].present?
    end

    enrollments
  end

  # Internal: Collect type, section, state, and role info from params and format them
  # for use in a request for the requester's own enrollments.
  # index is :course or :user
  #
  # Returns [ sql fragment string, replacement hash ]
  def enrollment_index_conditions(use_course_state = false)
    type, state, role = params.values_at(:type, :state, :role)
    clauses = []
    replacements = {}

    if role.present?
      clauses << 'COALESCE (enrollments.role_name, enrollments.type) IN (:role)'
      replacements[:role] = Array(role)
    elsif type.present?
      clauses << 'enrollments.type IN (:type)'
      replacements[:type] = Array(type)
    end

    if state.present?
      if use_course_state
        clauses << "(#{state.map{|s| "(#{User.enrollment_conditions(s.to_sym)})" }.join(' OR ')})"
      else
        clauses << 'enrollments.workflow_state IN (:workflow_state)'
        replacements[:workflow_state] = Array(state)
      end
    end

    if @section.present?
      clauses << 'enrollments.course_section_id = :course_section_id'
      replacements[:course_section_id] = @section.id
    end

    [ clauses.join(' AND '), replacements ]
  end
end
