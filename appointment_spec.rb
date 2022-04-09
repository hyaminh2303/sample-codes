require 'rails_helper'
require_relative 'concerns/clinic_as_tenant_shared'

RSpec.describe Appointment, type: :model do
  it_behaves_like "Clinic as a Tenant"

  it { is_expected.to belong_to(:patient) }
  it { is_expected.to belong_to(:doctor) }
  it { is_expected.to belong_to(:appointment_type) }
  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:referencer_doctor) }
  it { is_expected.to have_many(:appointment_event_logs).dependent(:destroy) }
  it { is_expected.to have_one(:visit_record).dependent(:nullify) }

  it { is_expected.to validate_presence_of(:patient) }
  it { is_expected.to validate_presence_of(:doctor) }
  it { is_expected.to validate_presence_of(:appointment_type) }
  it { is_expected.to validate_presence_of(:start_time) }
  it { is_expected.to validate_presence_of(:end_time) }
  it { is_expected.to validate_presence_of(:color) }

  describe 'validate color' do
    context 'calendar_colors_enabled is checked' do
      it 'creates a new appointment' do
        AppSetting.current.update(calendar_colors_enabled: true)
        expect {
          create(:appointment, color: nil)
        }.to change(Appointment, :count).by(1)
      end
    end

    context 'calendar_colors_enabled is unchecked' do
      it 'should validate color' do
        AppSetting.current.update(calendar_colors_enabled: false)
        appointment = build(:appointment, color: nil)
        expect(appointment).to have(1).errors_on(:color)
      end
    end
  end

  # Deactivated cause this validation was commented in the model
  xdescribe 'validate referencer doctor' do
    context 'supports_referencer_doctors is checked' do
      it 'should error on referencer_doctor' do
        AppSetting.current.update(supports_referencer_doctors: true)
        appointment = build(:appointment, referencer_doctor_id: nil)
        expect(appointment).to have(1).errors_on(:referencer_doctor)
      end
    end

    context 'supports_referencer_doctors is unchecked' do
      it 'creates a new appointment' do
        AppSetting.current.update(supports_referencer_doctors: false)
        expect {
          create(:appointment, referencer_doctor_id: nil)
        }.to change(Appointment, :count).by(1)
      end
    end
  end

  describe 'presence of reference_file' do
    context 'with is_reference_required from appointment type' do
      before(:each) do
        @appointment_type = create(:appointment_type, is_reference_required: true)
      end

      it 'is invalid without referenced_from_doctor flag' do
        appointment = build(:appointment, appointment_type: @appointment_type)
        expect(appointment).to have(1).errors_on(:reference_file)
      end

      it 'is valid factory with referenced_from_doctor flag' do
        appointment = build(:appointment, appointment_type: @appointment_type, referenced_from_doctor: true)
        expect(appointment).to be_valid
      end
    end

    context 'without is_reference_required from appointment type' do
      it 'is valid factory' do
        appointment = build(:appointment, appointment_type: create(:appointment_type, is_reference_required: false))
        expect(appointment).to be_valid
      end
    end
  end

  it 'validates valid patient_validate_failed and patient_validated' do
    appointment = build(:appointment, patient_validated: true, patient_validate_failed: true)
    expect(appointment).to have(1).errors_on(:patient_validate_failed)
  end

  it 'validates state before update' do
    appointment = create(:appointment, assisted: false)
    appointment.update_column(:aasm_state, 'billed')
    appointment.update(assisted: true)
    expect(appointment).to have(1).errors_on(:assisted)
  end

  it 'does not validates chilren appointment if parent is invalid' do
    expect_any_instance_of(AppointmentsRepeaterService).not_to receive(:validate)
    appointment = build(:recurrent_appointment, patient_id: nil)
    appointment.save
  end

  it "has a valid factory" do
    expect(build(:appointment)). to be_valid
  end

  it "is invalid without a is_all_day flag" do
    appointment = build(:appointment, is_all_day: nil)
    expect(appointment).to have(1).errors_on(:is_all_day)
  end

  it "is invalid without an assisted flag" do
    appointment = build(:appointment, assisted: nil)
    expect(appointment).to have(1).errors_on(:assisted)
  end

  describe "#start_time_cannot_be_in_the_past" do
    context "appointments_can_start_in_the_past setting is off" do
      it "is invalid if start time is set in the past" do
        appointment = build(:appointment, start_time: (Time.current.prev_week(Date.beginning_of_week)))
        expect(appointment).to have(1).errors_on(:start_time)
      end
    end

    context "appointments_can_start_in_the_past setting is on" do
      it "is valid if start time is set in the past" do
        AppSetting.current.update_attribute(:appointments_can_start_in_the_past, true)
        appointment = build(:appointment, start_time: (Time.current.prev_week(Date.beginning_of_week)))
        expect(appointment).to be_valid
      end
    end
  end

  describe "#only_one_appointement_per_doctor_at_a_time_exists" do
    context "multiple bookings setting is off" do
      before(:each) do
        AppSetting.current.update_attribute(:concurrent_appointments_for_doctor_allowed, false)
      end

      describe "appointment is starting on same time range of another appointment for the same doctor" do
        context "appointment starts at the same time" do
          xit "is invalid" do
            start_time = DateTime.current.next_week.advance(days: 2) + 3.hours
            doctor = create(:doctor)
            create(:appointment, start_time: start_time, doctor: doctor)
            appointment = build(:appointment, start_time: start_time, doctor: doctor)

            expect(appointment).to have(1).errors_on(:start_time)
          end
        end

        context "appointment starts inside the time range of another appointment" do
          it "is invalid" do
            start_time = DateTime.current.next_week.advance(days: 2) + 3.hours
            end_time = start_time + 3.hours
            doctor = create(:doctor)
            create(:appointment, start_time: start_time, doctor: doctor, end_time: end_time)
            appointment = build(:appointment, start_time: start_time + 1.hour, doctor: doctor)

            expect(appointment).to have(1).errors_on(:start_time)
          end
        end

        context "appointment starts after the time range of another appointment" do
          it "is valid" do
            start_time = DateTime.current.next_week.advance(days: 2) + 3.hours
            end_time = start_time + 4.hours
            doctor = create(:doctor)
            create(:appointment, start_time: start_time, doctor: doctor, end_time: end_time)
            appointment = build(:appointment, start_time: start_time + 5.hours, end_time: start_time + 6.hours, doctor: doctor)

            expect(appointment).to be_valid
          end
        end
      end
    end

    context "multiple bookings setting is on" do
      before(:each) do
        AppSetting.current.update_attribute(:concurrent_appointments_for_doctor_allowed, true)
      end

      describe "appointment is starting on the time range of another appointment for the same doctor" do
        context "appointment starts at the same time" do
          it "is valid" do
            start_time = DateTime.current.next_week.advance(days: 2) + 3.hours
            doctor = create(:doctor)
            create(:appointment, start_time: start_time, end_time: start_time + 1.hours, doctor: doctor)
            appointment = build(:appointment, start_time: start_time, end_time: start_time + 1.hours, doctor: doctor)

            expect(appointment).to be_valid
          end
        end

        context "appointment starts inside the time range of another appointment" do
          it "is valid" do
            start_time = DateTime.current.next_week.advance(days: 2) + 3.hours
            end_time = start_time + 3.hours
            doctor = create(:doctor)
            create(:appointment, start_time: start_time, doctor: doctor, end_time: end_time)
            appointment = build(:appointment, start_time: start_time + 1.hour, end_time: end_time + 1.hours, doctor: doctor)

            expect(appointment).to be_valid
          end
        end
      end
    end
  end

  it "is invalid if the day of the appointment is on sunday and clinic doesn't work on sunday" do
    start_time = DateTime.current.next_week.advance(days: 6)
    AppSetting.current.update_attribute(:work_on_sunday_enabled, false)
    appointment = build(:appointment, start_time: start_time)

    expect(appointment).to have(1).errors_on(:start_time)
  end

  it 'validates conflicts existence on recurrency' do
    doctor = create(:doctor)
    create(:appointment,
      start_time: 1.hour.from_now,
      end_time: 3.hour.from_now,
      doctor: doctor
    )

    appointment = build(:appointment, start_time: 2.hour.from_now, doctor: doctor)
    appointment.save

    expect(appointment).to have(1).errors_on(:start_time)
  end

  describe "an all day event" do
    before(:each) do
      @time = DateTime.current.next_week.advance(days: 2) + 30.minutes
      @appointment = create(:appointment, is_all_day: true, start_time: @time)
    end

    it "sets the start_time to the beginning of day of the start_time date" do
      expect(@appointment.start_time).to eq @time.in_time_zone.beginning_of_day
    end

    it "sets the end_time to the end of day of the start_time date" do
      expect(@appointment.end_time).to eq @time.in_time_zone.end_of_day
    end
  end

  describe 'repeat appointment after created' do
    context 'with notifications_for_periodic_appointments_enabled enabled' do
      it 'doesnt repeat the list of appontment' do
        AppSetting.current.update(
          notifications_for_periodic_appointments_enabled: true
        )

        appointment = create(:recurrent_appointment)
        expect(appointment.is_initial_recurrency).to be false
        expect(Appointment.where(parent_id: appointment.id)).to be_empty
      end
    end

    context 'with notifications_for_periodic_appointments_enabled disabled' do
      it 'repeats appointments after create if recurrency' do
        AppSetting.current.update(
          notifications_for_periodic_appointments_enabled: false
        )

        appointment = create(:recurrent_appointment)
        expect(appointment.is_initial_recurrency).to be true
        expect(Appointment.where(parent_id: appointment.id)).not_to be_empty
      end
    end
  end

  describe "filters by doctor" do
    before(:each) do
      @dr_jones = create(:doctor, last_name: "Jones")
      @dr_merlin = create(:doctor, last_name: "Merlin")
      @appointment_with_dr_jones = create(:appointment, doctor: @dr_jones)
      @appointment_with_dr_merlin = create(:appointment, doctor: @dr_merlin)
    end

    context "matching doctor" do
      it "returns an array of results that match" do
        expect(Appointment.by_doctor(@dr_jones)).to eq [@appointment_with_dr_jones]
      end
    end

    context "non-matching doctor" do
      it "returns an array of results that match" do
        expect(Appointment.by_doctor(@dr_jones)).to_not include @appointment_with_dr_merlin
      end
    end
  end

  describe "filters by patient" do
    before(:each) do
      @mr_smith = create(:patient, last_name: "Smith")
      @mr_doe = create(:patient, last_name: "Doe")
      @appointment_for_mr_smith = create(:appointment, patient: @mr_smith)
      @appointment_for_mr_doe = create(:appointment, patient: @mr_doe)
    end

    context "matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient(@mr_smith)).to eq [@appointment_for_mr_smith]
      end
    end

    context "non-matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient(@mr_smith)).to_not include @appointment_for_mr_doe
      end
    end

    context "canceled by patient" do
      it "returns an array of canceled appointments" do
        @appointment_for_mr_smith.update(canceled: true)
        expect(Appointment.canceled_by_patient(@mr_smith)).to eq [@appointment_for_mr_smith]
      end
    end
  end

  describe "filters by patient's name" do
    before(:each) do
      @mr_smith = create(:patient, last_name: "Smith", first_name: 'Ramírez')
      @mr_doe = create(:patient, last_name: "Doe", first_name: 'Jack')
      @appointment_for_mr_smith = create(:appointment, patient: @mr_smith)
      @appointment_for_mr_doe = create(:appointment, patient: @mr_doe)
    end

    context "matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient_name(@mr_smith.first_name)).to eq [@appointment_for_mr_smith]
        expect(Appointment.by_patient_name(@mr_smith.last_name)).to eq [@appointment_for_mr_smith]
        expect(Appointment.by_patient_name(@mr_smith.first_name.first(3))).to eq [@appointment_for_mr_smith]
        expect(Appointment.by_patient_name(@mr_smith.last_name + ' ' + @mr_smith.first_name)).to eq [@appointment_for_mr_smith]
      end
    end

    context "non-matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient_name(@mr_smith.first_name)).to_not include @appointment_for_mr_doe
        expect(Appointment.by_patient_name(@mr_smith.last_name)).to_not include @appointment_for_mr_doe
      end
    end
  end

  describe "filters by patient's government id" do
    before(:each) do
      @mr_smith = create(:patient, government_id: '115940524')
      @mr_doe = create(:patient, government_id: '889940524')
      @appointment_for_mr_smith = create(:appointment, patient: @mr_smith)
      @appointment_for_mr_doe = create(:appointment, patient: @mr_doe)
    end

    context "matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient_government_id(@mr_smith.government_id)).to eq [@appointment_for_mr_smith]
        expect(Appointment.by_patient_government_id(@mr_smith.government_id.first(3))).to eq [@appointment_for_mr_smith]
      end
    end

    context "non-matching patient" do
      it "returns an array of results that match" do
        expect(Appointment.by_patient_government_id(@mr_smith.government_id)).to_not include @appointment_for_mr_doe
        expect(Appointment.by_patient_government_id(@mr_smith.government_id.first(3))).to_not include @appointment_for_mr_doe
      end
    end
  end

  describe "filters by time range" do
    before(:each) do
      @time = DateTime.current.next_week.advance(days: 2) + 30.minutes
      @appointment = create(:appointment, start_time: @time, end_time: (@time + 30.minutes))
    end

    context "with records within time range" do
      it "returns an array of results that match" do
        start_time = @time - 30.minutes
        end_time = @time + 1.hour
        expect(Appointment.by_time_range(start_time, end_time)).to match_array([@appointment])
      end
    end

    context "without records within time range" do
      it "returns an array of results that match" do
        start_time = @time - 2.hours
        end_time = @time - 1.hour
        expect(Appointment.by_time_range(start_time, end_time)).to_not include @appointment
      end
    end
  end

  describe "#starting_at_future_window of 48 hours, with a 1 hour window" do
    before(:each) do
      # Ensure this test always run
      AppSetting.current.update_attribute(:work_on_sunday_enabled, true)

      # Setting window
      start_time = Time.current + 2.days + 1.minute # adjustment for running time
      end_time = start_time + 2.minutes

      @in_range_appointment = create(:appointment, start_time: start_time,
                                                   end_time: end_time)
      @out_of_range_appointment = create(:appointment, start_time: start_time + 1.hour,
                                                       end_time: end_time + 1.hour)
    end

    context "records with a start time in 48 hours time window" do
      it "returns an array of only results that match" do
        appointments_in_window = Appointment.starting_at_future_window(48, 1)
        expect(appointments_in_window).to include(@in_range_appointment)
        expect(appointments_in_window).not_to include(@out_of_range_appointment)
      end
    end

    context "without records with a start time in 24 hours time window" do
      it "returns an empty array" do
        expect(Appointment.starting_at_future_window(24, 1)).to be_empty
      end
    end
  end

  describe "filters by current date" do
    before(:each) do
      AppSetting.current.update_attribute(:work_on_sunday_enabled, true) # Ensure always run
      start_time = Time.current + 1.minutes
      end_time = start_time + 1.minutes

      @appointment = create(:appointment, start_time: start_time, end_time: end_time)
      create(:appointment, start_time: start_time + 1.days, end_time: end_time + 1.days)
    end

    context "records with a start time for the current date" do
      it "returns an array of results that match" do
        expect(Appointment.for_today).to match_array([@appointment])
      end
    end

    context "without records with a start time for the current date" do
      it "returns an empty array" do
        @appointment.update_attribute(:start_time, (Time.current + 1.days).beginning_of_day)
        expect(Appointment.for_today).to be_empty
      end
    end
  end

  it 'scopes appointments with recursion' do
    create_list(:appointment, 3)

    a = create(:appointment, recursive: true)
    b = create(:appointment, recursive: true)

    expect(Appointment.with_recursion).to include(b).and include(a)
  end

  it 'scopes appointments in the future' do
    create(:appointment, start_time: 1.hours.from_now)
    create(:appointment, start_time: 3.hours.from_now)

    a = create(:appointment, start_time: 1.days.from_now)
    b = create(:appointment, start_time: 2.days.from_now)

    expect(Appointment.in_future_from(DateTime.current + 4.hour)).to include(b).and include(a)
  end

  it "delegates patient phone to #phone" do
    patient = build(:patient, phone: "2222-2222")
    appointment = create(:appointment, patient: patient)
    expect(appointment.phone).to eq "2222-2222"
  end

  it "delegates to patient secondary phone #secondary_phone" do
    patient = build(:patient, secondary_phone: "2222-2222")
    appointment = create(:appointment, patient: patient)
    expect(appointment.secondary_phone).to eq "2222-2222"
  end

  it "returns the patient full name as the appointment title" do
    patient = build(:patient, first_name: "John", last_name: "Doe")
    appointment = create(:appointment, patient: patient)
    expect(appointment.title).to eq "Doe, John"
  end

  it "returns it's type name" do
    appointment = build(:appointment)
    expect(appointment.type_name).to eq appointment.appointment_type.name
  end

  it 'formats to string' do
    appointment = build(:appointment, start_time: Time.new(2007,11,6,12,0,0,"-06:00"))
    patient = appointment.patient
    patient.update_attributes(first_name: "Pedro", last_name: "Navajas")

    expect(appointment.to_s).to eq "06/11/2007 12:00 PM - Navajas, Pedro"
  end

  describe 'returns its frequency time' do
    context 'no frequency specified' do
      it 'returns zero' do
        appointment = create(:appointment)
        expect(appointment.frequency_time).to eq(0)
      end
    end

    context 'frequency specified' do
      it 'returns the associated frequency' do
        appointment = create(:appointment, frequency: :monthly)
        expect(appointment.frequency_time).to eq(1.month)
      end
    end
  end

  describe "sets it's start and end time from a string" do
    context "with valid string format" do
      before(:each) do
        @appointment = build(:appointment)
        time_zone = Rails.application.secrets.time_zone
        @time = DateTime.new(1990, 12, 20, 8, 0, 0, time_zone)
        @appointment.time = "20-12-1990-8-00"
      end

      it "sets the start time to the provided time" do
        expect(@appointment.start_time).to eq @time
      end

      it "sets the end time to the provided time plus 30 minutes" do
        expect(@appointment.end_time).to eq (@time + 30.minutes)
      end
    end

    context "with an invalid string format" do
      it "raises an ArgumentError" do
        @appointment = build(:appointment)
        @time = DateTime.new(1990, 12, 20, 8, 0, 0, '-6')
        expect{
          @appointment.time = "unformatted string"
        }.to raise_error(ArgumentError)
      end
    end
  end

  describe 'set aasm state' do
    before(:each) do
      @appointment = create(:appointment)
    end

    it 'set state to being_attended when call event start!' do
      @appointment.start!
      expect(@appointment.reload.being_attended?).to be_truthy
    end

    it 'set state to waiting_for_results when call event finalize!' do
      visit_record = create(:visit_record)
      @appointment.start!
      @appointment.finalize!(visit_record)
      expect(@appointment.reload.waiting_for_results?).to be_truthy
    end

    it 'picks next patient after finalize event' do
      visit_record = create(:visit_record)
      @appointment.start!
      expect(NextPatientPickupService).to receive_message_chain(:new, :run)
      @appointment.finalize!(visit_record)
    end

    it 'create log event after completed an event' do
      @appointment.start!
      visit_record = create(:visit_record)
      @appointment.finalize!(visit_record)
      expect(@appointment.appointment_event_logs.count).to eq(2)
    end

    it 'sends notification after changed to :waiting_for_results' do
      @appointment.start!
      visit_record = create(:visit_record)
      expect {
        @appointment.finalize!(visit_record)
      }.to change(Notification, :count).by(1)
      expect(Notification.last.notification_object).to eq(visit_record)
    end

    it 'sends broadcast to hide patient after start event' do
      expect(Broadcast::AppointmentBroadcaster).to receive_message_chain(:new, :broadcast_empty_patient_queue_for_doctor)
      @appointment.start!
    end

    describe 'after print events' do
      context 'pre_registration_enabled' do
        it 'adds line to financial record' do
          AppSetting.current.update(pre_registration_enabled: true)
          @appointment.print!

          financial_record_lines_count = @appointment.patient.financial_record.financial_record_lines.count
          expect(financial_record_lines_count).to eq 1
        end
      end

      context 'pre registration is not enabled' do
        it 'doesnt add a financial_record line' do
          @appointment.print!

          financial_record_lines_count = @appointment.patient.financial_record.financial_record_lines.count
          expect(financial_record_lines_count).to eq 0
        end
      end
    end

    it 'set status appointment_just_created after create' do
      expect(@appointment.appointment_just_created?).to be_truthy
    end

    it 'set status appointment_confirmed after create' do
      appointment = create(:appointment, assisted: true)
      expect(appointment.appointment_confirmed?).to be_truthy
    end

    it 'update status to appointment_confirmed after confirmed' do
      @appointment.update(assisted: true)
      expect(@appointment.reload.appointment_confirmed?).to be_truthy
    end

    it 'sends notification and email to referencer doctor' do
      user = create(:referencer_doctor_user)
      @appointment = create(:appointment, referencer_doctor: user.referencer_doctor)
      @appointment.start!
      visit_record = create(:visit_record)
      @appointment.finalize!(visit_record)
      expect {
        @appointment.complete_appointment!
      }.to change(Notification.unscope(where: :user_id), :count).by(1)

      expect(Notification.unscope(where: :user_id).first.notification_object).to eq(@appointment)
      last_email = ActionMailer::Base.deliveries.last

      expect(last_email.to).to eq [@appointment.referencer_doctor.user.email]
    end
  end

  it 'sends email notification on update to patient' do
    doctor = create(:doctor)
    @appointment = create(:appointment)
    @appointment.update(doctor_id: doctor.id)
    last_email = ActionMailer::Base.deliveries.last

    expect(last_email.to).to eq [@appointment.patient.email]
  end

  it 'sends deletion email notification to patient' do
    @appointment = create(:appointment)
    @appointment.update(canceled: true)
    last_email = ActionMailer::Base.deliveries.last

    expect(last_email.to).to eq [@appointment.patient.email]
  end

  describe 'return background color' do
    before(:each) do
      appointment_type = create(:appointment_type, color: '#ffffff')
      @appointment = create(:appointment, color: '#000000', appointment_type: appointment_type)
    end

    context 'calendar_colors_enabled is checked' do
      it 'return default color' do
        AppSetting.current.update(calendar_colors_enabled: true)
        expect(@appointment.background_color).to eq('#000000')
      end

      it 'return color in setting' do
        AppSetting.current.update(calendar_colors_enabled: true)
        appointment_state = create(:appointment_state)
        create(:appointment_state_color, color: 'dddddd', state: Appointment.aasm.states.map(&:name)[0], appointment_state: appointment_state)
        expect(@appointment.background_color).to eq('#dddddd')
      end
    end

    context 'calendar_colors_enabled is unchecked' do
      context 'appointment_type_color_enabled is checked' do
        it 'return color in appointment type color' do
          AppSetting.current.update(appointment_type_color_enabled: true)
          expect(@appointment.background_color).to eq('#ffffff')
        end
      end

      context 'appointment_type_color_enabled is unchecked' do
        it 'return color in appointment' do
          AppSetting.current.update(appointment_type_color_enabled: false)
          expect(@appointment.background_color).to eq('#000000')
        end
      end
    end
  end

  describe 'validates appointment state before updating canceled field' do
    before(:each) do
      AppSetting.current.update(enable_appointment_state_log: true)
      @appointment = create(:appointment)
    end

    it 'should not cancel appointment on non-deletable status' do
      @appointment.update_attribute(:aasm_state, 'patient_being_validated')
      @appointment.update(canceled: true)
      expect(@appointment.reload.canceled).to be_falsey
    end
  end

  it 'validate start time and end time' do
    appointment = build(:appointment, start_time: 2.days.from_now, end_time: 1.day.from_now)
    expect(appointment).to have(1).errors_on(:end_time)
  end

  it 'update patient package appointment type' do
    doctor1 = create(:doctor)
    doctor2 = create(:doctor)
    patient_packages_appointment_type = create(:patient_packages_appointment_type, doctor: doctor1)
    appointment = create(:appointment,
                         patient_package: patient_packages_appointment_type.patient_package,
                         patient_packages_appointment_type: patient_packages_appointment_type,
                         doctor: doctor1)
    appointment.update(doctor: doctor2)
    expect(patient_packages_appointment_type.reload.doctor).to eq(doctor2)
  end

  it 'should not raise error if patient_packages_appointment_type was deleted' do
    doctor1 = create(:doctor)
    doctor2 = create(:doctor)
    patient_packages_appointment_type = create(:patient_packages_appointment_type, doctor: doctor1)
    appointment = create(:appointment,
                         patient_package: patient_packages_appointment_type.patient_package,
                         patient_packages_appointment_type: patient_packages_appointment_type,
                         doctor: doctor1)
    appointment.update(doctor: doctor2)
    patient_packages_appointment_type.destroy
    expect(appointment.reload.doctor).to eq(doctor2)
  end

  describe "#belongs_to_patient_package?" do
    before(:each) do
      doctor = create(:doctor)
      patient_packages_appointment_type = create(:patient_packages_appointment_type, doctor: doctor)
      @patient_package = patient_packages_appointment_type.patient_package
      @appointment = create(:appointment, patient_package: @patient_package,
                           patient_packages_appointment_type: patient_packages_appointment_type,
                           doctor: doctor)
    end

    it 'returns true if patient_package is not deleted' do
      expect(@appointment.reload.belongs_to_patient_package?).to be_truthy
    end

    it 'returns false if patient_package is soft-deleted' do
      @patient_package.destroy
      expect(@appointment.reload.belongs_to_patient_package?).to be_falsey
    end
  end

  it 'marks billed for appointments with the same patient package' do
    patient_package = create(:patient_package)
    appointment_1 = create(:appointment, patient_package: patient_package)
    appointment_2 = create(:appointment, patient_package: patient_package)

    patient_package.destroy

    appointment_1.update(canceled: true)
    expect(appointment_2.canceled).to be_falsey
  end

  it 'should not marks billed for appointments with the same deleted patient package' do
    patient_package = create(:patient_package)
    appointment_1 = create(:appointment, patient_package: patient_package)
    appointment_2 = create(:appointment, patient_package: patient_package)

    patient_package.destroy

    appointment_1.bill!
    expect(appointment_2.billed?).to be_falsey
  end

  it 'should not remove appointments with the same deleted patient package' do
    patient_package = create(:patient_package)
    appointment_1 = create(:appointment, patient_package: patient_package)
    appointment_2 = create(:appointment, patient_package: patient_package)

    patient_package.destroy

    appointment_1.update(canceled: true)
    expect(appointment_2.canceled).to be_falsey
  end

  it 'should not confirm appointments with the same deleted patient package' do
    patient_package = create(:patient_package)
    appointment_1 = create(:appointment, patient_package: patient_package)
    appointment_2 = create(:appointment, patient_package: patient_package)

    patient_package.destroy

    appointment_1.update(assisted: true)
    expect(appointment_2.assisted).to be_falsey
  end

  describe '#send_notification_on_update_to_patient' do
    context "needs to send notification" do
      before(:each) do
        @appointment = create(:appointment)

        message_delivery = instance_double(ActionMailer::MessageDelivery)
        expect(AppointmentsMailer).to receive(:send_notification_on_update_to).
                                       with(@appointment).and_return(message_delivery)
        expect(message_delivery).to receive(:deliver_now)
      end

      it 'sends notification on updated start_time' do
        @appointment.update(start_time: @appointment.start_time + 1.minute)
      end

      it 'sends notification on updated end_time' do
        @appointment.update(end_time: @appointment.end_time + 1.minute)
      end

      it 'sends notification on updated patient_id' do
        @appointment.update(patient_id: create(:patient).id)
      end

      it 'sends notification on updated doctor_id' do
        @appointment.update(doctor_id: create(:doctor).id)
      end

      it 'sends notification on updated frequency' do
        @appointment.update(frequency: :monthly)
      end
    end

    context "doesn't need to send notification" do
      before(:each) do
        @appointment = create(:appointment)

        message_delivery = instance_double(ActionMailer::MessageDelivery)
        expect(AppointmentsMailer).not_to receive(:send_notification_on_update_to)
        expect(message_delivery).not_to receive(:deliver_now)
      end

      it 'does not send notification on updated description' do
        @appointment.update(description: '123456789')
      end

      it 'does not send notification on updated referencer_doctor_id' do
        @appointment.update(referencer_doctor_id: create(:doctor).id)
      end

      it 'does not send notification on updated appointment type' do
        @appointment.update(appointment_type_id: create(:appointment_type).id)
      end
    end
  end
end
