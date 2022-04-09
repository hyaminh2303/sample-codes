require 'rails_helper'

RSpec.feature 'Appointments', type: :feature, js: true do

  after(:each) { reset_session_and_wait_for_unfinished_requests }

  before(:each) do
    user = create(:business_admin_user, password: '12345678')
    login_as user
    visit appointments_path
  end

  describe 'Swithching mode' do
    context 'from normal to parallel mode' do
      it 'shows new filter with doctors' do
        page.find('.fc-multiColAgendaDay-button', match: :first).click

        expect(page).to have_content('Médicos:')
        expect(page).to have_selector('.filter-with-parallel-doctors-picker')
      end
    end

    context 'from parallel to normal mode' do
      it 'shows new filter with doctor' do
        page.find('.fc-multiColAgendaDay-button', match: :first).click
        click_on 'mes'
        expect(page).to have_content('Médico:')
        expect(page).to have_selector('.filter-with-simple-doctors-picker')
      end
    end
  end

  describe 'Appointment creation' do
    it 'doesnt show technician in doctor list to select' do
      technician = create(:doctor, is_technician: true)
      visit new_appointment_path

      options = page.all('select#appointment_doctor_id option').map(&:value)
      expect(options).not_to include(technician.id)
    end

    it 'redirects to new appointment page with date range' do
      page.find('.fc-multiColAgendaDay-button', match: :first).click
      click_on 'mes'
      page.find(:css, "td[data-date='#{Time.current.strftime("%Y-%m-%d")}']",
                      match: :first).click()
      sleep(1)
      expect(current_path).to eq(new_appointment_path)
      expect(URI::decode_www_form(URI.parse(current_url).query)
        .to_h["appointment[time]"])
        .to eq("#{DateTime.current.strftime("%-d-%-m-%Y-0-0")}")
    end

    context 'with parallel view' do
      it 'redirects to new appointment page with doctor id' do
        create_list(:doctor, 3)
        visit appointments_path
        page.find('.fc-multiColAgendaDay-button', match: :first).click

        page.execute_script("$('#doctor_ids').multiselect('select', #{Doctor.first.id})")
        click_on 'Filtrar'

        page.find(:css, "td[data-date='#{Time.current.strftime("%Y-%m-%d")}']",
                        match: :first).click()
        expect(current_path).to eq(new_appointment_path)
        expect(URI::decode_www_form(URI.parse(current_url).query)
          .to_h["appointment[doctor_id]"]).to eq(Doctor.first.id.to_s)
      end
    end
  end

  describe 'Appointment drag & drop' do
    # scenario doesn't work on last day of the month, and it's not worth to be corrected
    if Date.today != Date.today.end_of_month
      it 'updates appointment date' do
        last_day_of_current_month = Date.today.at_end_of_month.to_datetime

        appointment = create(:appointment,
          start_time: last_day_of_current_month.change(hour: 8),
          end_time: last_day_of_current_month.change(hour: 9)
        )
        visit appointments_path
        click_on 'mes'

        event = page.find('.fc-day-grid-event', match: :first)
        first_day = page.find(:css,
          "td[data-date='#{(last_day_of_current_month + 6.hours)
          .strftime("%Y-%m-%d")}']", match: :first
        )
        event.drag_to(first_day)

        sleep(2)
        appointment.reload
        expect(appointment.start_time.strftime('%d/%m/%Y')).to(
          eq((last_day_of_current_month + 6.hours).strftime('%d/%m/%Y')))
      end
    end

    context 'with parallel view' do
      it 'update appointment doctor id' do
        create_list(:doctor, 3)
        @doctor = Doctor.not_technician.order(is_technician_device: :asc).first
        appointment = create(:appointment,
          start_time: (Time.now + 1.day).change(hour: 14),
          end_time: (Time.now + 1.day).change(hour: 15),
          doctor: @doctor
        )

        visit appointments_path
        page.find('.fc-multiColAgendaDay-button', match: :first).click

        Doctor.all.each do |doctor|
          page.execute_script("$('#doctor_ids').multiselect('select', #{doctor.id})")
        end
        click_on 'Filtrar'
        page.find(:css, '.fc-today-button').click
        page.find('.fc-next-button.fc-corner-right', match: :first).click
        sleep(1)
        event = page.find('.fc-time-grid-event', match: :first)
        first_day = page.find(:css,
          "td[data-date='#{(Time.now + 1.day).strftime("%Y-%m-%d")}']", match: :first)
        event.drag_to(first_day)
        sleep(2)
        appointment.reload
        expect(appointment.doctor).to eq(@doctor)
      end
    end
  end

  it "filters patient's appointment in the modal" do
    AppSetting.current.update(visualize_appointment_in_modal_enabled: true)
    visit appointments_path
    expect(page).to have_selector(:css, '.filter-modal')
    fill_in 'government_id', with: '123'
    find(:css, ".filter-modal").click
    sleep(1)
    expect(page).to have_selector(:css, '#patient-appointments-modal')
  end

  scenario "Disable button invoice if appointment was billed" do
    AppSetting.current.update(enable_appointment_state_log: true)
    user = create(:business_admin_user, password: '12345678')
    create(:payment_option, name: 'Efectivo')
    create(:emitter_entity_for_electronic_invoice,
           legal_name: 'factory invoicing entity').id
    @appointment = create(:appointment)
    login_as user
    step1_go_to_edit_appointment_page_and_click_on_button_billing
    step2_click_save_invoice_and_should_update_appointment_billed_attribute
    step3_visit_edit_appointment_page_and_should_see_button_billing_as_disabled
  end

  scenario "Confirm an appointment" do
    AppSetting.current.update(confirmation_on_appointment_enabled: true)
    @paient = create(:patient)
    @appointment = create(:appointment, patient_id: @paient.id, assisted: false)
    AppointmentsMailer.recordatory(@appointment).deliver_now

    open_email(@appointment.patient.email)
    expect(current_email).to have_content('Confirmar Asistencia')
    current_email.click_link 'Confirmar Asistencia'
    expect(@appointment.reload.aasm_state).to eq('appointment_confirmed')
  end

  scenario 'Only change set default end time when edit mode' do
    appointment = create(:appointment,
                         start_time: (Time.current + 1.day).change(hour: 8),
                         end_time: (Time.current + 1.day).change(hour: 9))
    visit(edit_appointment_path(appointment))

    end_time = appointment.end_time.strftime('%d/%m/%Y %I:%M %p')
    expect(page).to have_selector("input[value=\'#{end_time}\']")
  end

  scenario 'print appointment' do
    appointment = create(:appointment,
                         start_time: (Time.current + 1.day).change(hour: 8),
                         end_time: (Time.current + 1.day).change(hour: 9))
    visit(edit_appointment_path(appointment))
    page.find(:css, '.form-actions .dropdown-toggle').click
    expect(page).to have_selector(:css, '.btn-print-appointment')
  end

  scenario 'print appointment content' do
    doctor = create(:doctor, is_technician_device: false, is_technician: false)
    appointment = create(:appointment,
                         start_time: (Time.current + 1.day).change(hour: 8),
                         end_time: (Time.current + 1.day).change(hour: 9), doctor: doctor)

    visit print_appointment_path(appointment)

    start_time = appointment.start_time.strftime('%I:%M %p')
    expect(page).to have_content('HORA DISPOSITIVO: N/A')
    expect(page).to have_content("HORA MÉDICO: #{start_time}")

    device_doctor = create(:doctor, is_technician_device: true)
    second_appointment = create(:appointment,
                                start_time: (Time.current + 1.day).change(hour: 8),
                                end_time: (Time.current + 1.day).change(hour: 9),
                                doctor: device_doctor)

    visit print_appointment_path(second_appointment)
    expect(page).to have_content('HORA MÉDICO: N/A')
    start_time = appointment.start_time.strftime('%I:%M %p')
    expect(page).to have_content("HORA DISPOSITIVO: #{start_time}")
  end

  scenario 'print appointment voucher' do
    appointment = create(:appointment,
                         start_time: (Time.current + 1.day).change(hour: 8),
                         end_time: (Time.current + 1.day).change(hour: 9))
    visit(edit_appointment_path(appointment))
    page.find(:css, '.form-actions .dropdown-toggle').click
    expect(page).to have_selector(:css, '.btn-print-full-appointment-voucher')
    expect(page).to have_selector(:css, '.btn-print-short-appointment-voucher')
  end

  scenario 'visualize calendar in new window' do
    logout(:user)
    user = create(:medical_admin_user, password: '12345678')
    login_as user
    appointment_request = create(:appointment_request)
    new_appointment_params = {
      patient_id: appointment_request.patient_id,
      appointment_type_id: appointment_request.appointment_type_id,
      referencer_doctor_id: appointment_request.referencer_doctor_id,
      time: (Time.current + 1.hours).strftime("%d-%m-%Y-%H-0"),
      referenced_from_doctor: true,
      description: appointment_request.description
    }

    visit new_appointment_path(appointment: new_appointment_params)
    new_window = window_opened_by { click_link 'Visualizar Agenda' }
    within_window new_window do
      expect(page).to have_selector("div[data-is-from-appointment-request='true']")
    end
  end

  scenario 'only shown exclusively doctors associated with medical admin in the list to select' do
    logout(:user)
    user = create(:medical_admin_user, password: '12345678')
    doctor_1 = create(:doctor)
    doctor_2 = create(:doctor)
    user.exclusively_access_allowed_doctors << doctor_1
    login_as user
    visit new_appointment_path

    options = page.all('select#appointment_doctor_id option', visible: false).map(&:value)
    expect(options).to include(doctor_1.id.to_s)
    expect(options).not_to include(doctor_2.id.to_s)
  end

  scenario 'add canceled reason' do
    AppSetting.current.update(justify_deleting_appointments_enabled: true)

    appointment = create(:appointment,
                         start_time: (Time.current + 1.day).change(hour: 8),
                         end_time: (Time.current + 1.day).change(hour: 9))

    visit(edit_appointment_path(appointment))
    click_link 'Eliminar'
    sleep 2
    expect(page).to have_selector('#appointment_cancellation_reason')

    fill_in 'appointment[cancellation_reason]', with: '123'
    page.find(:css, '#remove-appointment-modal button[type="submit"]').click
    sleep 2
    expect(Appointment.unscoped.last.cancellation_reason).to eq('123')
  end

  def step1_go_to_edit_appointment_page_and_click_on_button_billing
    visit edit_appointment_path(@appointment)
    sleep 3
    click_on 'Facturar'
    expect(page).to have_current_path(new_invoice_path(appointment_id: @appointment.id))
  end

  def step2_click_save_invoice_and_should_update_appointment_billed_attribute
    select 'Efectivo', from: 'invoice[payments_attributes][0][payment_option_id]'
    fill_in 'invoice[payments_attributes][0][amount]',
            with: @appointment.appointment_type.price, visible: false
    fill_in 'invoice[government_id]',
            with: '12345678'
    select 'factory invoicing entity',
            from: 'invoice[invoicing_entity_id]', visible: false
    click_on 'Crear Factura'
    expect(@appointment.reload.billed?).to be_truthy
  end

  def step3_visit_edit_appointment_page_and_should_see_button_billing_as_disabled
    visit edit_appointment_path(@appointment)
    expect(find_link('Facturar')[:disabled]).to be_truthy
  end

  scenario 'bill a package' do
    AppSetting.current.update(enable_appointment_state_log: true)
    user = create(:business_admin_user, password: '12345678')
    create(:payment_option, name: 'Efectivo')
    create(:emitter_entity_for_electronic_invoice,
           legal_name: 'factory invoicing entity').id
    @new_appointment_type = create(:appointment_type)
    @service_package = create(:service_package)
    @product = create(:product, quantity: 10)
    @patient_package = create(:patient_package, service_package: @service_package)
    @appointment = create(:appointment, appointment_type: @new_appointment_type,
                                        patient_package: @patient_package)
    create(:appointment_types_product, appointment_type: @new_appointment_type,
           product: @product, quantity: 2)
    create(:service_packages_appointment_type, appointment_type: @new_appointment_type,
           service_package: @service_package)
    login_as user
    step1_go_to_edit_appointment_page_and_click_on_button_billing
    step2_should_see_package_was_selected
    step3_product_should_be_removed_from_inventory
  end

  def step2_should_see_package_was_selected
    select 'Efectivo', from: 'invoice[payments_attributes][0][payment_option_id]'
    expect(find(:css, '.appointment_type select', visible: false, match: :first).value)
      .to eq(@service_package.to_global_id.to_s)
  end

  def step3_product_should_be_removed_from_inventory
    sleep(10)
    click_on 'Crear Factura'
    sleep(2)
    expect(@product.reload.quantity).to eq(8)
  end

  scenario "Confirm an appointment" do
    AppSetting.current.update(confirmation_on_appointment_enabled: true)
    @paient = create(:patient)
    @appointment = create(:appointment, patient_id: @paient.id, assisted: false)
    AppointmentsMailer.recordatory(@appointment).deliver_now

    open_email(@appointment.patient.email)
    expect(current_email).to have_content('Confirmar Asistencia')
    current_email.click_link 'Confirmar Asistencia'
    expect(@appointment.reload.aasm_state).to eq('appointment_confirmed')
  end

  scenario "use appointment type color" do
    step1_appointment_type_color_enabled_not_checked_and_should_not_see_color_input
    step2_appointment_type_color_enabled_is_checked_and_should_see_color_input
  end

  def step1_appointment_type_color_enabled_not_checked_and_should_not_see_color_input
    AppSetting.current.update(appointment_type_color_enabled: false)
    visit new_appointment_type_path
    expect(page).not_to have_selector('#appointment_type_color', visible: false)
  end

  def step2_appointment_type_color_enabled_is_checked_and_should_see_color_input
    AppSetting.current.update(appointment_type_color_enabled: true)
    visit new_appointment_type_path
    expect(page).to have_selector('#appointment_type_color', visible: false)
  end

  scenario "displays time picker with the interval from setting" do
    AppSetting.current.update(time_picker_minutes_interval: 20)
    visit new_appointment_path
    page.find('#appointment_start_time').click
    sleep 1
    expect(page).to have_selector(".ui-timepicker-select[data-step='20']")
  end

  scenario 'should not show invoice button if patient package is deleted' do
    AppSetting.current.update(enable_appointment_state_log: true)

    patient_package = create(:patient_package)
    appointment = create(:appointment, patient_package: patient_package)
    appointment.update_column(:aasm_state, :appointment_completed)
    visit edit_appointment_path(appointment)
    expect(page).to have_content("Facturar")
    patient_package.destroy
    sleep 2
    visit edit_appointment_path(appointment)
    expect(page).not_to have_content("Facturar")
  end

end
