class Appointment < ActiveRecord::Base
  include ClinicAsTenant
  include AASM
  include BroadcastHandler

  attr_accessor :save_from_now_on

  belongs_to :patient, with_deleted: true
  belongs_to :doctor
  belongs_to :appointment_type, with_deleted: true
  belongs_to :user, with_deleted: true
  belongs_to :referencer_doctor
  belongs_to :patient_package, with_deleted: true
  belongs_to :patient_packages_appointment_type, with_deleted: true
  has_many :appointment_event_logs, dependent: :destroy
  has_one :visit_record, dependent: :nullify

  validates_inclusion_of :is_all_day, :assisted, in: [true, false]
  validates_presence_of :patient, :doctor, :appointment_type,
                        :start_time, :end_time
  validates_presence_of :color,
    unless: proc { AppSetting.current.calendar_colors_enabled? }
  # validates_presence_of :referencer_doctor,
  #   if: proc { AppSetting.current.supports_referencer_doctors? }
  validate :start_time_cannot_be_in_the_past
  validate :only_one_appointment_per_doctor_exists_at_a_time
  validate :appointments_on_sunday_only_if_clinic_works_on_sunday
  validate :absence_of_conflicts_if_recurrent, on: :create
  validate :check_appointment_status_before_mark_delete, on: :update
  validate :validate_patient
  validate :check_state_before_update, on: :update,
    if: proc { assisted_changed? && assisted? }
  validates_datetime :end_time, after: :start_time

  after_save :set_times_for_all_day_events

  after_create :repeat_appointments
  after_create :send_notification_to_patient,
    if: proc { parent_id.nil? && !Rails.env.test? }

  after_update :send_canceled_notification,
    if: proc { canceled_changed? && canceled? }
  after_update :validate_patient!,
    if: proc { patient_validated_changed? && patient_validated? }
  after_update :validate_patient_failed!,
    if: proc { patient_validate_failed_changed? && patient_validate_failed? }
  after_update :reset_sent_reminder_flag,
    if: proc { start_time_changed? }

  before_update :execute_recurrency_actions
  before_save :confirm_appointment, if: proc { assisted_changed? && assisted? }
  before_save :set_state_just_created, if: proc { assisted_was && assisted_changed? }
  before_save :confirm_appointments_with_the_same_patient_package,
    if: proc { assisted_changed? }
  after_update :remove_appointments_with_the_same_patient_package,
    if: proc { canceled_changed? }
  after_update :send_notification_on_update_to_patient, unless: proc { canceled_changed? }
  after_update :update_patient_package_appointment_type, if: proc { belongs_to_patient_package? }

  has_attached_file :reference_file
  do_not_validate_attachment_file_type :reference_file
  validates_attachment :reference_file, presence: true, if: proc {
    !referenced_from_doctor && appointment_type.try(:is_reference_required?)
  }

  default_scope { where(canceled: false) }
  scope :load_relations, -> { includes(:appointment_type, :patient) }
  scope :by_doctor, -> (doctor) { where(doctor_id: doctor.id) }
  scope :by_doctor_id, -> (doctor_id) { where(doctor_id: doctor_id) }
  scope :by_doctors, -> (doctors) { where(doctor_id: doctors.ids) }
  scope :by_patient, -> (patient) { where(patient_id: patient.id) }
  scope :by_patient_id, -> (patient_id) { where(patient_id: patient_id) }
  scope :with_recursion, -> { where(recursive: true) }
  scope :in_future_from, -> (start_time){ where('start_time >= ?', start_time) }
  scope :with_start_date_in_the_past, -> { where('start_time <= ?', Time.current) }
  scope :confirmed, -> { where(confirmed: true) }
  scope :without_reminder_sent, -> { where(reminder_sent: false) }

  scope :by_appointment_type_id, -> (appointment_type_id) {
    where(appointment_type_id: appointment_type_id)
  }
  scope :in_patient_package, -> (patient_package_id) {
    where(patient_package_id: patient_package_id)
  }
  scope :canceled_by_patient, -> (patient) {
    rewhere(patient_id: patient.id, canceled: true)
  }
  scope :by_time_range, -> (start, finish) { where(
      "(start_time between :start and :finish) OR " \
      "(end_time between :start and :finish) OR "\
      "( (start_time < :start) AND (:finish < end_time) )",
      start: start, finish: finish
    )
  }
  scope :by_patient_name, ->(name) {
    joins(:patient).where("
      REPLACE(patients.full_name, ',', '') ILIKE :name
      or patients.first_name ILIKE :name
      or patients.last_name ILIKE :name", name: "#{name}%")
  }
  scope :by_patient_government_id, ->(government_id) {
    joins(:patient).where("patients.government_id like ?", "#{government_id}%")
  }

  scope :for_today, (lambda do
    today = Time.current
    where("start_time between ? and ?", today.beginning_of_day,
      today.end_of_day).order("start_time ASC")
  end)

  scope :starting_at_future_window, -> (hours_into_the_future, hours_window) {
    future_block_start = Time.current + hours_into_the_future.hours
    future_block_end = future_block_start + hours_window.hours

    where(start_time: [future_block_start..future_block_end]).order("start_time ASC")
  }

  enum frequency: [:monthly, :weekly, :biweekly, :yearly]

  def send_notification_to_patient
    AppointmentsMailer.send_creation_notification_to(self).deliver_now
  end

  def send_notification_on_update_to_patient
    need_to_send_notification = false
    [
      :start_time,
      :end_time,
      :doctor_id,
      :patient_id,
      :frequency
    ].each do |attribute|
      if eval("#{attribute}_changed?")
        need_to_send_notification = true
        break
      end
    end

    if need_to_send_notification
      AppointmentsMailer.send_notification_on_update_to(self).deliver_now
    end
  end

  def frequency_time
    { monthly: frequency_number.month,
      weekly: frequency_number.week,
      biweekly: 2.weeks,
      yearly: frequency_number.years }[frequency.try(:to_sym)] || 0
  end

  def time= time_string
    begin
      day, month, year, hour, minute = time_string.split("-").map(&:to_i)
      second = 0
      timezone = Rails.application.secrets.time_zone
      date = DateTime.new(year, month, day, hour, minute, second, timezone)

      self.start_time = date
      self.end_time = (date + 30.minutes)
    rescue
      raise ArgumentError.new I18n.t("activerecord.errors.models.appointment." \
                                     "attributes.times.invalid_format")
    end
  end

  delegate :phone, to: :patient
  delegate :secondary_phone, to: :patient

  def title
    patient.present? ? patient.full_name : ''
  end

  def type_name
    AppointmentType.unscoped do # pulls the type name from deactivated types too
      reload if appointment_type.blank?
      appointment_type.name
    end
  end

  def date
    "#{start_time.strftime('%d/%m/%Y')}"
  end

  def hour
    "#{start_time.strftime('%I:%M %p')}"
  end

  def to_s
    "#{start_time.strftime('%d/%m/%Y %I:%M %p')} - #{title}"
  end

  aasm whiny_transitions: false, skip_validation_on_save: true do
    state :appointment_just_created, initial: true
    state :appointment_confirmed
    state :patient_being_validated
    state :arrived
    state :waiting_in_reception
    state :being_attended
    state :waiting_for_results
    state :appointment_completed
    state :failed_validation
    state :billed

    # Doctor's actions
    event :start, after_commit: :broadcast_hide_patient_info do
      transitions to: :being_attended
    end

    event :finalize,
      after_commit: Proc.new { |*args| after_finalize_actions(*args) }  do
      transitions from: :being_attended, to: :waiting_for_results
    end

    # Patient's actions
    event :print, after_commit: :call_events_after_print do
      transitions to: :patient_being_validated
    end

    # Secratary's actions
    event :complete_appointment,
      after_commit: :send_notification_and_email_to_referencer_doctor do
      transitions from: :waiting_for_results, to: :appointment_completed
    end

    event :confirm_appointment do
      transitions to: :appointment_confirmed
    end

    event :validate_patient, after_commit: :broadcast_new_patient_queue do
      transitions to: :arrived
    end

    event :validate_patient_failed do
      transitions to: :failed_validation
    end

    event :bill,
      after_commit: :mark_billed_for_appointments_with_the_same_patient_package do
      transitions to: :billed
    end

    event :set_state_just_created do
      transitions to: :appointment_just_created
    end

    after_all_events :save_event_log
  end

  def duration
    (end_time - start_time) / (60 * 60).to_f
  end

  def background_color
    if AppSetting.current.calendar_colors_enabled? &&
        aasm_state != 'waiting_in_reception' &&
        AppointmentStateColor.exists?(state: aasm_state)

      AppointmentState.current.get_color_for_state(aasm_state)
    else
      if AppSetting.current.appointment_type_color_enabled?
        appointment_type.color.presence || color
      else
        color
      end
    end
  end

  def cannot_delete?
    %w(patient_being_validated arrived waiting_in_reception being_attended
      waiting_for_results appointment_completed).include?(aasm_state) &&
    AppSetting.current.enable_appointment_state_log
  end

  def self.future_for_patient(params)
    patients = Patient

    if params[:government_id].present?
      patients = patients.where('government_id LIKE ?', "#{params[:government_id]}%")
    end

    if params[:name].present?
      patients = patients.filter_by_name(params[:name])
    end

    Appointment.in_future_from(DateTime.current).
                where(patient_id: patients.ids).
                order(start_time: :asc).limit(10)
  end

  def event_log_time(event_type)
    appointment_event_logs.by_state(event_type).first.try(:created_at)
  end

  def belongs_to_patient_package?
    patient_package.present? && !patient_package.deleted?
  end

  private

    def check_appointment_status_before_mark_delete
      if canceled_changed? && canceled? && cannot_delete?
        errors.add(:base, I18n.t(
          "activerecord.errors.models.appointment.attributes.canceled.cannot_delete",
          state: I18n.t("models.appointment_states.#{aasm_state}")
        ))
      end
    end

    def call_events_after_print
      create_financial_record_line if AppSetting.current.pre_registration_enabled?
    end

    def send_notification_and_email_to_referencer_doctor
      if referencer_doctor.present?
        Notification.create(user_id: referencer_doctor.user.id,
                            notification_object: self,
                            notification_type: :appointment_completed_notification
        )
        AppointmentsMailer.send_completion_notification_to(self).deliver_now
      end
    end

    def save_event_log
      appointment_event_logs.create(state: aasm.to_state) unless new_record?
    end

    def execute_recurrency_actions
      if frequency_changed?
        if frequency.present?
          unless free_of_conflicts?
            errors.add( :frequency, I18n.t("activerecord.errors.models.appointment." \
                                           "attributes.frequency.conflicts") )
            return false
          end

          AppointmentsRepeaterService.new(self).run
        else
          AppointmentsRemoverService.new(self).run
        end
      elsif is_modifying_times_of_recurrency?
        update_from_now_on
        return false unless errors.empty?
      end
    end

    def is_modifying_times_of_recurrency?
      (start_time_changed? || end_time_changed?) && save_from_now_on.present?
    end

    def free_of_conflicts?
      absence_of_conflicts_if_recurrent
      errors.empty?
    end

    def only_one_appointment_per_doctor_exists_at_a_time
      unless AppSetting.current.concurrent_appointments_for_doctor_allowed?
        if start_time.present? && doctor.present?
          appointments_where = Appointment.where(
            'start_time <= :new_appointment_start_time and ' \
            'end_time > :new_appointment_start_time and doctor_id = :doctor_id',
            new_appointment_start_time: start_time,
            doctor_id: doctor.id
          )

          unless new_record?
            appointments_where = appointments_where.where('id <> :id', id: self.id)
          end

          if appointments_where.count > 0
            errors[:start_time] << I18n.t("activerecord.errors.models.appointment." \
                                          "already_booked")
          end
        end
      end
    end

    def set_times_for_all_day_events
      if is_all_day?
        write_attribute(:start_time, start_time.beginning_of_day)
        write_attribute(:end_time, start_time.end_of_day)
      end
    end

    def start_time_cannot_be_in_the_past
      unless AppSetting.current.appointments_can_start_in_the_past?
        if start_time.present? && start_time < Time.current
          errors.add(:start_time, I18n.t("activerecord.errors.models.appointment."\
                                         "attributes.start_time.in_the_past")
          )
        end
      end
    end

    def appointments_on_sunday_only_if_clinic_works_on_sunday
      if start_time.present?
        if start_time.wday == 0 && !AppSetting.current.work_on_sunday_enabled
          errors.add(:start_time, I18n.t("activerecord.errors.models.appointment." \
                                         "attributes.start_time.on_sunday_disabled")
          )
        end
      end
    end

    def absence_of_conflicts_if_recurrent
      if patient.present? && !(frequency.nil? ||
        AppSetting.current.notifications_for_periodic_appointments_enabled?)
        recurrent_errors = AppointmentsRepeaterService.new(self).validate

        unless recurrent_errors.empty?
          errors.add(:start_time, recurrent_errors.first)
        end
      end
    end

    def repeat_appointments
      unless frequency.nil?
        self.update_columns(
          last_recurrent_start_date: start_time,
          last_recurrent_end_date: end_time,
          recursive: true
        )
        AppointmentsRepeaterService.new(self).run
      end
    end

    def update_from_now_on
      recurrent_errors = AppointmentsRepeaterService.new(self)
        .update_from_now_on
      unless recurrent_errors.empty?
        errors.add(:start_time, recurrent_errors.first)
      end
    end

    def send_state_notification(visit_record)
      Notification.create(
        notification_type: :visit_record_done_notification,
        notification_object: visit_record
      ) if visit_record.present?
    end

    def create_financial_record_line
      financial_record_line = if belongs_to_patient_package?
        patient.financial_record.financial_record_lines.find_or_initialize_by(
          billable: patient_package.service_package) do |line|
          line.doctor_id = doctor_id
          line.item_type = 'AppointmentType'
        end
      else
        patient.financial_record.financial_record_lines.find_or_initialize_by(
          billable: appointment_type,
          item_type: 'AppointmentType',
          doctor_id: doctor_id)
      end
      financial_record_line.save(validate: false)
      financial_record_line.appointments_financial_record_lines.create(appointment_id: id)
    end

    def send_canceled_notification
      Notification.create(
        notification_type: :appointment_canceled,
        notification_object: self
      )
      AppointmentsMailer.send_deletion_notification_to(self).deliver_now
    end

    def validate_patient
      if patient_validate_failed.present? && patient_validated.present?
        error_msg = I18n.t('activerecord.errors.messages.patient_validated')
        errors[:patient_validate_failed] << error_msg
      end
    end

    def check_state_before_update
      if !appointment_just_created?
        errors[:assisted] << I18n.t('activerecord.errors.messages.assisted_cannot_change')
      end
    end

    def mark_billed_for_appointments_with_the_same_patient_package
      return unless belongs_to_patient_package?
      self.class.in_patient_package(patient_package_id).update_all(aasm_state: 'billed')
    end

    def remove_appointments_with_the_same_patient_package
      return unless belongs_to_patient_package?
      self.class.in_patient_package(patient_package_id).update_all(canceled: true)
    end

    def confirm_appointments_with_the_same_patient_package
      return unless belongs_to_patient_package?
      assistance = assisted? ? 'appointment_confirmed' : 'appointment_just_created'
      self.class.in_patient_package(patient_package_id).
        update_all(assisted: assisted?, aasm_state: assistance)
    end

    def update_patient_package_appointment_type
      # The appointment is kept after the patient_packages_appointment_type is destroyed.
      # So if the user updates the appointment again, the system will raise an error:
      # "Cannot update a destroyed record", we won't update the patient_packages_appointment_type
      # to avoid the issue.
      return if patient_packages_appointment_type.deleted?

      patient_packages_appointment_type.update_columns(
        start_time: start_time,
        end_time: end_time,
        doctor_id: doctor_id,
        appointment_type_id: appointment_type_id,
        description: description
      )
    end

    def reset_sent_reminder_flag
      update_column(:reminder_sent, false)
    end

end

# == Schema Information
#
# Table name: appointments
#
#  aasm_state                           :string
#  appointment_type_id                  :integer
#  assisted                             :boolean          default(FALSE)
#  canceled                             :boolean          default(FALSE)
#  cancellation_reason                  :text
#  clinic_id                            :integer
#  color                                :string
#  confirmed                            :boolean          default(FALSE)
#  created_at                           :datetime         not null
#  description                          :text
#  doctor_id                            :integer
#  end_time                             :datetime
#  frequency                            :integer
#  frequency_number                     :integer          default(1)
#  id                                   :integer          not null, primary key
#  is_all_day                           :boolean          default(FALSE)
#  is_initial_recurrency                :boolean          default(FALSE)
#  last_recurrent_end_date              :datetime
#  last_recurrent_start_date            :datetime
#  migrated                             :boolean          default(FALSE)
#  parent_id                            :integer
#  patient_id                           :integer
#  patient_package_id                   :integer
#  patient_packages_appointment_type_id :integer
#  patient_validate_failed              :boolean          default(FALSE)
#  patient_validated                    :boolean          default(FALSE)
#  recursive                            :boolean
#  reference_file_content_type          :string
#  reference_file_file_name             :string
#  reference_file_file_size             :integer
#  reference_file_updated_at            :datetime
#  referenced_from_doctor               :boolean          default(FALSE)
#  referencer_doctor_id                 :integer
#  reminder_sent                        :boolean          default(FALSE)
#  start_time                           :datetime
#  updated_at                           :datetime         not null
#  user_id                              :integer
#
