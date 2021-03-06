class Thorax.Models.Query extends Thorax.Model
  idAttribute: '_id'
  urlRoot: '/api/queries'
  initialize: (attrs, options) ->
    @parent = options.parent
    @set 'patient_results', new Thorax.Collections.PatientResults [], parent: this
  # TODO what other final states are there other than completed?
  isPopulated: -> @has('status') and @get('status').state in ['completed']
  isLoading: -> !@isPopulated()
  isContinuous: -> 
    score = @parent.get('measure_scoring')
    if score == 'CONTINUOUS_VARIABLE'
      true
    else
      false
  ipp: -> if @isPopulated() and @has('result') then @get('result').IPP else 0
  measurePopulation: -> if @isPopulated() and @has('result') then @get('result').MSRPOPL else 0
  numerator: -> if @isPopulated() and @has('result') then @get('result').NUMER else 0
  denominator: -> if @isPopulated() and @has('result') then @get('result').DENOM else 0
  observation: -> if @isPopulated() and @has('result') then @get('result').OBSERV else 0
  hasExceptions: -> 
    if @has('DENEXCEP')
      true
    else
      false
  exceptions: -> if @isPopulated() and @has('result') then @get('result').DENEXCEP else 0
  hasExclusions: ->
    if @has('DENEX')
      true
    else
      false
  exclusions: -> if @isPopulated() and @has('result') then @get('result').DENEX else 0
  hasOutliers: -> !@isContinuous() and @has('antinumerator')
  outliers: -> if @isPopulated() and @has('result') then @get('result').antinumerator else 0
  performanceDenominator: -> @denominator() - @exceptions() - @exclusions()
  performanceRate: -> Math.round(100 * @numerator() / Math.max(1, @performanceDenominator()))
  aggregateResult: -> if @isPopulated() then @get('aggregate_result') else 0
  # hack so that creating a query acts just like checking an existing query
  fetch: ->
    if @isNew() then @save() else super(arguments...)
  result: -> _(@get('result')).extend performanceDenominator: @performanceDenominator()
