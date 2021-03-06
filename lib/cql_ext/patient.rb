# The Patient model is an extension of app/models/qdm/patient.rb as defined by CQM-Models.

module CQM
  class Patient
    field :correlation_id, type: BSON::ObjectId
    field :original_patient_id, type: BSON::ObjectId
    field :original_medical_record_number, type: String
    field :medical_record_number, type: String
    field :measure_relevance_hash, type: Hash, default: {}
    embeds_many :addresses # patient addresses
    embeds_many :telecoms

    # This allows us to instantiate Patients that do not belong to specific type of patient
    # for the purposes of testing but blocks us from saving them to the database to ensure
    # every patient actually in the database is of a valid type.
    validates :_type, inclusion: %w[CQM::BundlePatient CQM::VendorPatient CQM::ProductTestPatient CQM::TestExecutionPatient]

    after_initialize do
      self[:addresses] ||= [CQM::Address.new(
        use: 'HP',
        street: ['202 Burlington Rd.'],
        city: 'Bedford',
        state: 'MA',
        zip: '01730',
        country: 'US'
      )]
      self[:telecoms] ||= [CQM::Telecom.new(
        use: 'HP',
        value: '555-555-2003'
      )]
    end

    def destroy
      calculation_results.destroy
      delete
    end

=begin    def product_test
      ProductTest.where('_id' => correlation_id).most_recent
    end
=end

    def bundle
      if !self['bundleId'].nil?
        Bundle.find(self['bundleId'])
      elsif !correlation_id.nil?
        ProductTest.find(correlation_id).bundle
      end
    end

    def age_at(date)
      dob = Time.at(qdmPatient.birthDatetime).in_time_zone
      date.year - dob.year - (date.month > dob.month || (date.month == dob.month && date.day >= dob.day) ? 0 : 1)
    end

    def original_patient
      Patient.find(original_patient_id) if original_patient_id
    end

    def lookup_provider(include_address = nil)
      # find with provider id hash i.e. "$oid"->value
      provider = providers.first
      addresses = []
      provider.addresses.each do |address|
        addresses << { 'street' => address.street, 'city' => address.city, 'state' => address.state, 'zip' => address.zip,
                       'country' => address.country }
      end

      return { 'npis' => [provider.npi], 'tins' => [provider.tin], 'addresses' => addresses } if include_address

      { 'npis' => [provider.npi], 'tins' => [provider.tin] }
    end

    def duplicate_randomization(augmented_patients, random: Random.new)
      patient = clone
      changed = { original_patient_id: id, first: [first_names, first_names], last: [familyName, familyName] }
      patient, changed = randomize_patient_name_or_birth(patient, changed, augmented_patients, random: random)
      randomize_demographics(patient, changed, random: random)
    end

    #
    # private
    #
    # TODO: R2P: use private keyword?
    def first_names
      givenNames.join(' ')
    end

    def randomize_patient_name_or_birth(patient, changed, augmented_patients, random: Random.new)
      case random.rand(21) # random chooses which part of the patient is modified. Limit birthdate to ~1/20
      when 0..9 # first name
        patient = Cypress::NameRandomizer.randomize_patient_name_first(patient, augmented_patients, random: random)
        changed[:first] = [first_names, patient.first_names]
      when 10..19 # last name
        patient = Cypress::NameRandomizer.randomize_patient_name_last(patient, augmented_patients, random: random)
        changed[:last] = [familyName, patient.familyName]
      when 20 # birthdate
        Cypress::DemographicsRandomizer.randomize_birthdate(patient.qdmPatient, random: random)
        changed[:birthdate] = [qdmPatient.birthDatetime, patient.qdmPatient.birthDatetime]
      end
      [patient, changed]
    end

    def payer
      payer_element = qdmPatient.get_data_elements('patient_characteristic', 'payer')
      if payer_element&.any? && payer_element.first.dataElementCodes &&
         payer_element.first.dataElementCodes.any?
        payer_element.first.dataElementCodes.first['code']
      end
    end

    def gender
      gender_chars = qdmPatient.get_data_elements('patient_characteristic', 'gender')
      if gender_chars&.any? && gender_chars.first.dataElementCodes && gender_chars.first.dataElementCodes.any?
        gender_chars.first.dataElementCodes.first['code']
      end
    end

    def race
      race_element = qdmPatient.get_data_elements('patient_characteristic', 'race')
      if race_element&.any? && race_element.first.dataElementCodes &&
         race_element.first.dataElementCodes.any?
        race_element.first.dataElementCodes.first['code']
      end
    end

    def ethnicity
      ethnicity_element = qdmPatient.get_data_elements('patient_characteristic', 'ethnicity')
      if ethnicity_element&.any? && ethnicity_element.first.dataElementCodes &&
         ethnicity_element.first.dataElementCodes.any?
        ethnicity_element.first.dataElementCodes.first['code']
      end
    end

    def randomize_demographics(patient, changed, random: Random.new)
      case random.rand(3) # now, randomize demographics
      when 0 # gender
        Cypress::DemographicsRandomizer.randomize_gender(patient, random)
        changed[:gender] = [gender, patient.gender]
      when 1 # race
        Cypress::DemographicsRandomizer.randomize_race(patient, random)
        changed[:race] = [race, patient.race]
      when 2 # ethnicity
        Cypress::DemographicsRandomizer.randomize_ethnicity(patient, random)
        changed[:ethnicity] = [ethnicity, patient.ethnicity]
      end
      [patient, changed, self]
    end

    # A method for storing if a patient is relevant to a specific measure.  This method iterates through a set
    # of individal results and flags a patient as relevant if they calculate into the measures population
    def update_measure_relevance_hash(individual_result)
      ir = individual_result
      # Create a new hash for a measure, if one doesn't already exist
      measure_relevance_hash[ir.measure_id.to_s] = {} unless measure_relevance_hash[ir.measure_id.to_s]
      # Iterate through each population for a measure
      CQM::Measure.find(ir.measure_id).population_keys.each do |pop_key|
        # A patient is only relevant to the MSRPOPL if they are not also into the MSRPOPLEX
        # MSRPOPL is the only population that has an additional requirement for 'relevance'
        # Otherwise, if there is a count for the population, the relevance can be set to true
        if pop_key == 'MSRPOPL'
          measure_relevance_hash[ir.measure_id.to_s]['MSRPOPL'] = true if (ir['MSRPOPL'].to_i - ir['MSRPOPLEX'].to_i).positive?
        elsif ir[pop_key].to_i.positive?
          measure_relevance_hash[ir.measure_id.to_s][pop_key] = true
        end
      end
    end
    def cache_results(params = {})
      query = {"extendedData.medical_record_number" => self._id.to_s }
      query["extendedData.effective_date"]= params["effective_date"] if params["effective_date"]
      #query["extendedData.effective_start_date"]= params["effective_start_date"] if params["effective_start_date"]
      query["extendedData.hqmf_id"]= params["measure_id"] if params["measure_id"]
      #query["value.sub_id"]= params["sub_id"] if params["sub_id"]
      Delayed::Worker.logger.info("*********** what is the results query ***************")
      Delayed::Worker.logger.info(query)

      CQM::IndividualResult.where(query)
    end
    # Return true if the patient is relevant for one of the population keys in one of the measures passed in
    def patient_relevant?(measure_ids, population_keys)
      measure_relevance_hash.any? do |measure_key, mrh|
        # Does the list of measure include the key from the measure relevance hash, and
        # Does the measure relevance include a true value from on of the requested population keys.
        (measure_ids.include? BSON::ObjectId.from_string(measure_key)) && (population_keys.any? { |pop| mrh[pop] == true })
      end
    end
  end

  class BundlePatient < Patient; end

  class VendorPatient < Patient; end

  class ProductTestPatient < Patient; end

  class TestExecutionPatient < Patient; end
end

Patient = CQM::Patient
BundlePatient = CQM::BundlePatient
VendorPatient = CQM::VendorPatient
ProductTestPatient = CQM::ProductTestPatient
TestExecutionPatient = CQM::TestExecutionPatient
