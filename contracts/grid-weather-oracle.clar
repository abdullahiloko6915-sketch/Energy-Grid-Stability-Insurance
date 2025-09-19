;; Grid Weather Oracle Contract
;; Combined oracle for grid stability metrics and weather impact on renewable generation
;; Provides real-time data feeds for parametric insurance calculations

;; === CONSTANTS ===

;; Error codes for oracle operations
(define-constant ERR_UNAUTHORIZED u1001)
(define-constant ERR_INVALID_DATA u1002)
(define-constant ERR_STALE_DATA u1003)
(define-constant ERR_THRESHOLD_BREACH u1004)
(define-constant ERR_INSUFFICIENT_ORACLES u1005)
(define-constant ERR_DATA_NOT_FOUND u1006)
(define-constant ERR_INVALID_TIMESTAMP u1007)
(define-constant ERR_ORACLE_ALREADY_EXISTS u1008)

;; System configuration constants
(define-constant MINIMUM_ORACLES u3)
(define-constant DATA_FRESHNESS_THRESHOLD u3600) ;; 1 hour in seconds
(define-constant GRID_FREQUENCY_NORMAL_MIN u4980) ;; 49.8 Hz * 100 for precision
(define-constant GRID_FREQUENCY_NORMAL_MAX u5020) ;; 50.2 Hz * 100 for precision
(define-constant VOLTAGE_NORMAL_MIN u21000) ;; 210V * 100 for precision
(define-constant VOLTAGE_NORMAL_MAX u24000) ;; 240V * 100 for precision
(define-constant WIND_SPEED_MAX_SAFE u2500) ;; 25 m/s * 100 for precision
(define-constant SOLAR_IRRADIANCE_MAX u120000) ;; 1200 W/m2 * 100 for precision

;; === DATA VARIABLES ===

;; Contract owner for administrative functions
(define-data-var contract-owner principal tx-sender)

;; Global oracle configuration
(define-data-var oracle-count uint u0)
(define-data-var data-update-count uint u0)
(define-data-var emergency-mode bool false)

;; === DATA MAPS ===

;; Oracle registration and authorization
(define-map oracle-registry
  { oracle-address: principal }
  { 
    authorized: bool,
    reputation-score: uint,
    last-update: uint,
    total-submissions: uint,
    failed-submissions: uint
  }
)

;; Grid stability metrics storage
(define-map grid-stability-data
  { timestamp: uint, oracle: principal }
  {
    frequency: uint, ;; Grid frequency in hundredths of Hz (5000 = 50.00 Hz)
    voltage: uint, ;; Voltage in hundredths of volts (23000 = 230.00V)
    load-factor: uint, ;; Load factor percentage * 100 (8500 = 85.00%)
    outage-duration: uint, ;; Outage duration in seconds
    grid-instability-score: uint ;; Calculated instability score 0-10000
  }
)

;; Weather data storage for renewable energy impact
(define-map weather-data
  { timestamp: uint, oracle: principal }
  {
    solar-irradiance: uint, ;; Solar irradiance in W/m2 * 100
    wind-speed: uint, ;; Wind speed in m/s * 100
    temperature: uint, ;; Temperature in Celsius * 100
    humidity: uint, ;; Humidity percentage * 100
    cloud-cover: uint, ;; Cloud cover percentage * 100
    precipitation: uint ;; Precipitation in mm * 100
  }
)

;; Aggregated data consensus storage
(define-map consensus-data
  { data-type: (string-ascii 32), timestamp: uint }
  {
    value: uint,
    confidence-level: uint,
    contributing-oracles: uint,
    calculation-method: (string-ascii 64)
  }
)

;; Threshold breach events for insurance triggers
(define-map threshold-events
  { event-id: uint }
  {
    event-type: (string-ascii 32),
    timestamp: uint,
    severity: uint, ;; 1-100 scale
    affected-metrics: (list 10 (string-ascii 32)),
    trigger-conditions: (string-ascii 256),
    resolution-timestamp: (optional uint)
  }
)

;; === PUBLIC FUNCTIONS ===

;; Register a new oracle operator
(define-public (register-oracle (oracle-address principal))
  (begin
    ;; Only contract owner can register oracles
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    ;; Check if oracle already exists
    (asserts! (is-none (map-get? oracle-registry { oracle-address: oracle-address })) (err ERR_ORACLE_ALREADY_EXISTS))
    
    ;; Register the new oracle
    (map-set oracle-registry
      { oracle-address: oracle-address }
      {
        authorized: true,
        reputation-score: u5000, ;; Start with neutral reputation
        last-update: u0,
        total-submissions: u0,
        failed-submissions: u0
      }
    )
    
    ;; Increment oracle count
    (var-set oracle-count (+ (var-get oracle-count) u1))
    (ok true)
  )
)

;; Submit grid stability data from authorized oracles
(define-public (submit-grid-data 
  (frequency uint) 
  (voltage uint) 
  (load-factor uint) 
  (outage-duration uint)
  (timestamp uint))
  (let (
    (oracle-info (unwrap! (map-get? oracle-registry { oracle-address: tx-sender }) (err ERR_UNAUTHORIZED)))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    (instability-score (calculate-instability-score frequency voltage load-factor outage-duration))
  )
    ;; Verify oracle is authorized
    (asserts! (get authorized oracle-info) (err ERR_UNAUTHORIZED))
    ;; Verify timestamp is not in the future and not too old
    (asserts! (<= timestamp current-time) (err ERR_INVALID_TIMESTAMP))
    (asserts! (>= timestamp (- current-time DATA_FRESHNESS_THRESHOLD)) (err ERR_STALE_DATA))
    
    ;; Store grid stability data
    (map-set grid-stability-data
      { timestamp: timestamp, oracle: tx-sender }
      {
        frequency: frequency,
        voltage: voltage,
        load-factor: load-factor,
        outage-duration: outage-duration,
        grid-instability-score: instability-score
      }
    )
    
    ;; Update oracle statistics
    (update-oracle-stats tx-sender true)
    
    ;; Check for threshold breaches and create events if necessary
    (check-grid-thresholds frequency voltage instability-score timestamp)
    
    (ok instability-score)
  )
)

;; Submit weather data from authorized oracles
(define-public (submit-weather-data
  (solar-irradiance uint)
  (wind-speed uint)
  (temperature uint)
  (humidity uint)
  (cloud-cover uint)
  (precipitation uint)
  (timestamp uint))
  (let (
    (oracle-info (unwrap! (map-get? oracle-registry { oracle-address: tx-sender }) (err ERR_UNAUTHORIZED)))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    ;; Verify oracle is authorized
    (asserts! (get authorized oracle-info) (err ERR_UNAUTHORIZED))
    ;; Verify timestamp validity
    (asserts! (<= timestamp current-time) (err ERR_INVALID_TIMESTAMP))
    (asserts! (>= timestamp (- current-time DATA_FRESHNESS_THRESHOLD)) (err ERR_STALE_DATA))
    ;; Validate data ranges
    (asserts! (<= wind-speed WIND_SPEED_MAX_SAFE) (err ERR_INVALID_DATA))
    (asserts! (<= solar-irradiance SOLAR_IRRADIANCE_MAX) (err ERR_INVALID_DATA))
    
    ;; Store weather data
    (map-set weather-data
      { timestamp: timestamp, oracle: tx-sender }
      {
        solar-irradiance: solar-irradiance,
        wind-speed: wind-speed,
        temperature: temperature,
        humidity: humidity,
        cloud-cover: cloud-cover,
        precipitation: precipitation
      }
    )
    
    ;; Update oracle statistics
    (update-oracle-stats tx-sender true)
    
    ;; Check for weather-related threshold breaches
    (check-weather-thresholds wind-speed solar-irradiance timestamp)
    
    (ok true)
  )
)

;; Create consensus data from multiple oracle submissions
(define-public (create-consensus (data-type (string-ascii 32)) (timestamp uint))
  (let (
    (consensus-result (calculate-consensus data-type timestamp))
  )
    (asserts! (>= (get contributing-oracles consensus-result) MINIMUM_ORACLES) (err ERR_INSUFFICIENT_ORACLES))
    
    ;; Store consensus data
    (map-set consensus-data
      { data-type: data-type, timestamp: timestamp }
      consensus-result
    )
    
    (ok consensus-result)
  )
)

;; Emergency function to disable oracle or enter emergency mode
(define-public (emergency-action (action (string-ascii 32)) (target (optional principal)))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    
    (if (is-eq action "disable-oracle")
      (match target
        oracle-addr (begin
          (map-set oracle-registry
            { oracle-address: oracle-addr }
            (merge (unwrap-panic (map-get? oracle-registry { oracle-address: oracle-addr })) 
                   { authorized: false })
          )
          (ok true)
        )
        (err ERR_INVALID_DATA)
      )
      (if (is-eq action "emergency-mode")
        (begin
          (var-set emergency-mode true)
          (ok true)
        )
        (err ERR_INVALID_DATA)
      )
    )
  )
)

;; === READ-ONLY FUNCTIONS ===

;; Get grid stability data for a specific timestamp and oracle
(define-read-only (get-grid-data (timestamp uint) (oracle principal))
  (map-get? grid-stability-data { timestamp: timestamp, oracle: oracle })
)

;; Get weather data for a specific timestamp and oracle
(define-read-only (get-weather-data (timestamp uint) (oracle principal))
  (map-get? weather-data { timestamp: timestamp, oracle: oracle })
)

;; Get consensus data for a specific type and timestamp
(define-read-only (get-consensus-data (data-type (string-ascii 32)) (timestamp uint))
  (map-get? consensus-data { data-type: data-type, timestamp: timestamp })
)

;; Get oracle information and statistics
(define-read-only (get-oracle-info (oracle-address principal))
  (map-get? oracle-registry { oracle-address: oracle-address })
)

;; Check if grid metrics are within normal operating ranges
(define-read-only (is-grid-stable (frequency uint) (voltage uint))
  (and
    (and (>= frequency GRID_FREQUENCY_NORMAL_MIN) (<= frequency GRID_FREQUENCY_NORMAL_MAX))
    (and (>= voltage VOLTAGE_NORMAL_MIN) (<= voltage VOLTAGE_NORMAL_MAX))
  )
)

;; Get current system status
(define-read-only (get-system-status)
  {
    oracle-count: (var-get oracle-count),
    data-updates: (var-get data-update-count),
    emergency-mode: (var-get emergency-mode),
    minimum-oracles: MINIMUM_ORACLES
  }
)

;; === PRIVATE FUNCTIONS ===

;; Calculate grid instability score based on multiple factors
(define-private (calculate-instability-score (frequency uint) (voltage uint) (load-factor uint) (outage-duration uint))
  (let (
    (freq-deviation (if (< frequency GRID_FREQUENCY_NORMAL_MIN)
                       (- GRID_FREQUENCY_NORMAL_MIN frequency)
                       (if (> frequency GRID_FREQUENCY_NORMAL_MAX)
                           (- frequency GRID_FREQUENCY_NORMAL_MAX)
                           u0)))
    (volt-deviation (if (< voltage VOLTAGE_NORMAL_MIN)
                       (- VOLTAGE_NORMAL_MIN voltage)
                       (if (> voltage VOLTAGE_NORMAL_MAX)
                           (- voltage VOLTAGE_NORMAL_MAX)
                           u0)))
    (load-penalty (if (> load-factor u9000) (* (- load-factor u9000) u2) u0))
    (outage-penalty (* outage-duration u10))
  )
    (+ freq-deviation volt-deviation load-penalty outage-penalty)
  )
)

;; Update oracle reputation and statistics
(define-private (update-oracle-stats (oracle-address principal) (success bool))
  (let (
    (current-stats (unwrap-panic (map-get? oracle-registry { oracle-address: oracle-address })))
    (new-total (+ (get total-submissions current-stats) u1))
    (new-failed (if success (get failed-submissions current-stats) (+ (get failed-submissions current-stats) u1)))
    (success-rate (* (/ (- new-total new-failed) new-total) u100))
    (new-reputation (/ (+ (get reputation-score current-stats) success-rate) u2))
  )
    (map-set oracle-registry
      { oracle-address: oracle-address }
      (merge current-stats {
        last-update: (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))),
        total-submissions: new-total,
        failed-submissions: new-failed,
        reputation-score: new-reputation
      })
    )
  )
)

;; Check grid stability thresholds and create events
(define-private (check-grid-thresholds (frequency uint) (voltage uint) (instability-score uint) (timestamp uint))
  (let (
    (grid-unstable (not (is-grid-stable frequency voltage)))
    (high-instability (> instability-score u5000))
  )
    (if (or grid-unstable high-instability)
      (create-threshold-event "grid-instability" timestamp 
                            (if high-instability u80 u60) 
                            (list "frequency" "voltage" "instability-score"))
      true
    )
  )
)

;; Check weather-related thresholds for renewable energy impact
(define-private (check-weather-thresholds (wind-speed uint) (solar-irradiance uint) (timestamp uint))
  (let (
    (high-wind (> wind-speed u2000)) ;; 20 m/s
    (low-solar (< solar-irradiance u20000)) ;; 200 W/m2
  )
    (if (or high-wind low-solar)
      (create-threshold-event "weather-impact" timestamp
                            (if high-wind u90 u50)
                            (list "wind-speed" "solar-irradiance"))
      true
    )
  )
)

;; Create a threshold breach event record
(define-private (create-threshold-event 
  (event-type (string-ascii 32)) 
  (timestamp uint) 
  (severity uint) 
  (metrics (list 10 (string-ascii 32))))
  (let (
    (event-id (var-get data-update-count))
  )
    (map-set threshold-events
      { event-id: event-id }
      {
        event-type: event-type,
        timestamp: timestamp,
        severity: severity,
        affected-metrics: metrics,
        trigger-conditions: "threshold-breach",
        resolution-timestamp: none
      }
    )
    (var-set data-update-count (+ event-id u1))
    true
  )
)

;; Calculate consensus from multiple oracle data points
(define-private (calculate-consensus (data-type (string-ascii 32)) (timestamp uint))
  ;; Simplified consensus calculation - in production would implement more sophisticated algorithms
  {
    value: u0, ;; Placeholder for calculated consensus value
    confidence-level: u85,
    contributing-oracles: (var-get oracle-count),
    calculation-method: "median-average"
  }
)

