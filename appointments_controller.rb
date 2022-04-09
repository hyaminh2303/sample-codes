class AppointmentsController < ApplicationController

  include AppointmentsHelper

  skip_before_action :authenticate_user!, only: [:confirm_appointment]
  authorize_resource except: [:confirm_appointment]

  before_action :set_settings
  before_action :set_appointment, only: [
    :show, :edit, :update, :destroy, :update_status,
    :print_label, :print, :print_appointment_voucher, :delete_appointment_form,
    :delete_appointment_with_reason
  ]

  before_action :check_medical_admin_access_permissions, only: [:edit, :update]

  # GET /appointments
  def index
    respond_to do |format|
      # Renders only the HTML page without appointments
      format.html do
        set_variables_to_apply_filters_when_present
        render layout: "application"
      end

      # This request sends via JSON all the appointments
      format.json do
        appointments_for_preview = []
        if params[:preview_patient_package].present?
          patient_package_params = JSON.parse(cookies[:patient_package_form_data])
          package_service = PatientPackageAppointmentsCreationService.new(
            PatientPackage.new(patient_package_params['patient_package'])
          )
          appointments_for_preview = package_service.run(true)
        end

        @appointments = CalendarLoaderService.new(
          params, is_current_user_only_a_doctor?, current_doctor, current_user
        ).run

        if is_paralell_doctors_filter_present?
          parallel_doctors_ids = params[:doctor_ids].split(',')
          dup_events_for_parallel_calendar(@appointments, parallel_doctors_ids)
        end

        appts_with_preview = @appointments.concat(appointments_for_preview)
        appointments_for_calendar = appts_with_preview.map do |appointment|
          appointment_to_calendar_hash(appointment, params, current_user)
        end

        render json: appointments_for_calendar.to_json
      end
    end
  end

  # GET /appointments/completed
  def completed
    @appointments = Appointment.appointment_completed
  end

  # GET /appointments/calendar_modal
  def calendar_modal
    set_variables_to_apply_filters_when_present
    render partial: 'calendar'
  end

  # GET /appointments/record_for_patient/:patient_id
  def medical_record
    @patient = Patient.find(params[:patient_id])

    if is_current_user_only_a_doctor?
      active_appointments = Appointment.by_patient(@patient)
                                       .by_doctor(current_doctor).to_a
    else
      active_appointments = Appointment.by_patient(@patient).to_a
    end

    canceled_appointments = Appointment.canceled_by_patient(@patient).to_a
    @appointments = active_appointments | canceled_appointments
    @appointments = @appointments.sort_by { |obj| obj.start_time }
  end

  # GET /appointments/1
  def show
    unless is_current_user_only_a_doctor? || is_current_user_an_inventory_admin?
      # Business && Medical Admins get the editable view, as they can edit
      redirect_path = if @appointment.belongs_to_patient_package?
                        edit_patient_package_path(@appointment.patient_package)
                      else
                        edit_appointment_path @appointment
                      end
      redirect_to redirect_path
    end
  end

  # GET /appointments/new
  def new
    appointment_attrs = (are_appointment_params_present? ? appointment_params : {})

    if params[:waiting_list_entry_id].present?
      @waiting_list_entry = WaitingListEntry.find(params[:waiting_list_entry_id])
      appointment_attrs = appointment_attrs
                            .merge(@waiting_list_entry.to_appointment_params)
    end
    @appointment = Appointment.new(appointment_attrs)
  end

  # GET /appointments/1/edit
  def edit
    if is_current_user_a_doctor? &&
       (@appointment.waiting_for_results? || @appointment.appointment_completed?)
      redirect_to visit_record_path(@appointment.visit_record)
    end
  end

  # POST /appointments
  def create
    @appointment = Appointment.new(appointment_params)
    @appointment.user = current_user

    if @appointment.save
      AppointmentBlockerService.new(nil, nil, session[:blocked_id], current_user.id)
      redirect_to appointments_url,
                  notice: I18n.t('controllers.femenine.created', model: @model_name)
    else
      render action: 'new'
    end
  end

  # PATCH/PUT /appointments/1
  def update
    appointment_attrs = appointment_params
    appointment_attrs.merge!(save_from_now_on: true) if save_from_now_on?

    if @appointment.update(appointment_attrs)
      if request.xhr?
        render json: {notice: I18n.t('controllers.femenine.updated', model: @model_name)}
      else
        redirect_path = if params[:from_assistance_confirmation].present? &&
                           params[:from_assistance_confirmation] != "false"
          assistances_path
        else
          appointments_path
        end

        redirect_to redirect_path,
                    notice: I18n.t('controllers.femenine.updated', model: @model_name)
      end
    else
      if request.xhr?
        render json: {errors: @appointment.errors}
      else
        render action: 'edit'
      end
    end
  end

  # DELETE /appointments/1
  def destroy
    if @appointment.update(canceled: true)
      AppointmentsRemoverService.new(@appointment).run if params[:series].present?

      redirect_to appointments_url,
        notice: I18n.t('controllers.femenine.deleted', model: @model_name)
    else
      redirect_to edit_appointment_path(@appointment),
                  notice: @appointment.errors.full_messages.to_sentence
    end
  end

  # POST /appointments/1/update_status
  def update_status
    @appointment.send(params[:event])
    redirect_to determine_redirect_path_after_update_status
  end

  # GET /appointments/check_locked_blocks_in_calendar
  def check_locked_blocks_in_calendar
    if current_user.has_role?(:business_admin)
      render json: { result: {errors: ''} } and return
    end

    service = AppointmentBlockerService.new(
      appointment_blocked_params,
      params[:id], session[:blocked_id],
      params[:blocked_flag],
      current_user.id
    )

    result = service.run
    session[:blocked_id] = result[:id] if result[:id].present?
    render json: { result: result, status: :ok }
  end

  # GET /appointments/appointments_for_patient
  def appointments_for_patient
    @appointments = Appointment.future_for_patient(params)
    render layout: false
  end

  # GET /appointments/1/confirm_appointment
  def confirm_appointment
    @appointment = Appointment.unscoped.find(params[:id])
    ActsAsTenant.current_tenant = @appointment.clinic

    if %w(appointment_just_created).include?(@appointment.aasm_state)
      @appointment.update_columns(assisted: true, aasm_state: 'appointment_confirmed')
      message = I18n.t('controllers.appointments.confirmed')
    else
      message = I18n.t('controllers.appointments.cannot_confirm')
    end

    redirect_path = user_signed_in? ? root_path : new_user_session_path
    redirect_to redirect_path, notice: message
  end

  # GET /appointments/1/print_label
  def print_label
    @print_title = 'Impresión de Etiqueta de Cita'
    respond_to do |format|
      format.html { render layout: "print" }
      format.pdf do
        @format = :pdf
        render pdf: "print", layout: "pdf", page_size: "Letter",
               template: "appointments/print_label.html.slim"
      end
    end
  end

  # GET /appointments/1/print
  def print
    @print_title = 'Impresión de Cita'
    respond_to do |format|
      format.html {render layout: "print"}
      format.pdf do
        @format = :pdf
        render pdf: "print",
               layout: "pdf",
               page_size: "Letter",
               template: "appointments/print.html.slim"
      end
    end
  end

  # GET /appointments/1/print_appointment_voucher
  def print_appointment_voucher
    @print_title = 'Comprobante de Asistencia'
    @size = (params[:size] ? params[:size] : "full")
    respond_to do |format|
      format.html {render layout: "print"}
      format.pdf do
        @format = :pdf
        render pdf: "print",
               layout: "pdf",
               page_size: "Letter",
               template: "appointments/print_appointment_voucher.html.slim"
      end
    end
  end

  # GET /appointments/1/delete_appointment_form
  def delete_appointment_form
    render layout: false
  end

  # POST /appointments/1/delete_appointment_with_reason
  def delete_appointment_with_reason
    cancellation_params = { canceled: true,
      cancellation_reason: cancel_appointment_params[:cancellation_reason] }

    if @appointment.update(cancellation_params)
      AppointmentsRemoverService.new(@appointment).run if params[:series].present?

      redirect_to appointments_url,
                  notice: I18n.t('controllers.femenine.deleted', model: @model_name)
    else
      redirect_to edit_appointment_path(@appointment),
                  notice: @appointment.errors.full_messages.to_sentence
    end
  end

  private

    def set_variables_to_apply_filters_when_present
      @work_on_sunday = AppSetting.current.work_on_sunday_enabled?
      @slot_size = AppSetting.current.calendar_slot_size

      if is_user_filtering_by_doctors? # single or parallel
        if is_paralell_doctors_filter_present?
          @doctors = Doctor.where(id: params[:doctor_ids])
                            .not_technician
                            .order_doctor_by_position_and_device
        else
          # single doctor filtering
          @doctor = Doctor.find_by(id: params[:doctor_id])
        end

        @filtered = true
      end

      if is_user_filtering_by_name_or_government?
        @name = params[:name]
        @government_id = params[:government_id]
        @filtered = true
      end
    end

    def set_appointment
      @appointment = Appointment.find(params[:id])
    end

    def set_settings
      @settings = AppSetting.current
    end

    def appointment_params
      params.require(:appointment).permit(:patient_id, :doctor_id, :referencer_doctor_id,
        :appointment_type_id, :start_time, :end_time, :is_all_day, :color,
        :description, :time, :start, :end, :assisted, :canceled, :frequency,
        :reference_file, :referenced_from_doctor, :frequency_number, :patient_validated,
        :patient_validate_failed, :cancellation_reason
      )
    end

    def cancel_appointment_params
      params.require(:appointment).permit(:cancellation_reason)
    end

    def appointment_blocked_params
      params.require(:appointment).permit(:doctor_id, :start_time, :end_time)
    end

    def is_user_filtering_by_doctors?
      is_single_doctor_filter_present? || is_paralell_doctors_filter_present?
    end

    def is_single_doctor_filter_present?
      params[:doctor_id].present?
    end

    def is_paralell_doctors_filter_present?
      params[:doctor_ids].present?
    end

    def is_user_filtering_by_name_or_government?
      params[:name].present? || params[:government_id].present?
    end

    def are_appointment_params_present?
      params[:appointment].present?
    end

    def save_from_now_on?
      params[:save_from_now_on].present?
    end

    def dup_events_for_parallel_calendar(appointments, doctor_ids)
      clone_items = []
      list_items_for_delete = []
      @appointments.each do |item|
        if item.class.name == "Event"
          doctors = item.doctors.where(id: doctor_ids)
          doctors.each do |doctor|
            clone_item = item.clone
            clone_item.doctor_id = doctor.id
            clone_items << clone_item
          end
          list_items_for_delete << item
        end
      end
      @appointments -= list_items_for_delete
      @appointments += clone_items
    end

    def determine_redirect_path_after_update_status
      if @appointment.being_attended?
        if @appointment.visit_record.present?
          edit_visit_record_path(@appointment.visit_record)
        else
          new_visit_record_path(patient_id: @appointment.patient_id,
                                appointment_id: @appointment.id)
        end
      else
        appointments_path
      end
    end

    def check_medical_admin_access_permissions
      return unless current_user.has_role?(:medical_admin)

      if current_user.exclusively_access_allowed_doctors.present? &&
        current_user.exclusively_access_allowed_doctors.exclude?(@appointment.doctor)

        redirect_to appointments_path, notice: I18n.t('http_errors.access_denied.message')
      end
    end
end
