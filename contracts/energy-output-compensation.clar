;; Energy Output Compensation Contract
;; Automated compensation for energy producers during grid instability or adverse weather
;; Handles policy management, premium collection, and instant payouts based on oracle triggers

;; === CONSTANTS ===

;; Error codes for compensation operations
(define-constant ERR_UNAUTHORIZED u2001)
(define-constant ERR_INSUFFICIENT_FUNDS u2002)
(define-constant ERR_POLICY_NOT_FOUND u2003)
(define-constant ERR_POLICY_EXPIRED u2004)
(define-constant ERR_POLICY_INACTIVE u2005)
(define-constant ERR_ALREADY_CLAIMED u2006)
(define-constant ERR_CLAIM_NOT_ELIGIBLE u2007)
(define-constant ERR_INVALID_PREMIUM u2008)
(define-constant ERR_INVALID_COVERAGE u2009)
(define-constant ERR_ORACLE_NOT_FOUND u2010)

;; Policy configuration constants
(define-constant MIN_POLICY_DURATION u86400) ;; 1 day in seconds
(define-constant MAX_POLICY_DURATION u31536000) ;; 1 year in seconds
(define-constant MIN_PREMIUM_AMOUNT u1000000) ;; 1 STX in micro-STX
(define-constant MAX_COVERAGE_AMOUNT u1000000000000) ;; 1M STX in micro-STX
(define-constant PREMIUM_CALCULATION_FACTOR u100) ;; Factor for premium calculations
(define-constant EMERGENCY_PAYOUT_PERCENTAGE u75) ;; 75% payout in emergency situations

;; Compensation trigger thresholds
(define-constant GRID_INSTABILITY_THRESHOLD u5000)
(define-constant WEATHER_IMPACT_THRESHOLD u6000)
(define-constant MINIMUM_OUTAGE_DURATION u300) ;; 5 minutes in seconds
(define-constant MAXIMUM_DAILY_CLAIMS u5) ;; Maximum claims per day per policy

;; === DATA VARIABLES ===

;; Contract administration
(define-data-var contract-owner principal tx-sender)
(define-data-var insurance-pool-balance uint u0)
(define-data-var policy-counter uint u0)
(define-data-var claim-counter uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-payouts-made uint u0)

;; System configuration
(define-data-var emergency-mode bool false)
(define-data-var oracle-contract principal tx-sender) ;; Will be updated to grid-weather-oracle contract
(define-data-var minimum-pool-balance uint u100000000000) ;; 100k STX reserve requirement

;; === DATA MAPS ===

;; Insurance policy records
(define-map insurance-policies
  { policy-id: uint }
  {
    policy-holder: principal,
    coverage-amount: uint, ;; Maximum payout amount in micro-STX
    premium-amount: uint, ;; Premium paid in micro-STX
    start-time: uint,
    end-time: uint,
    coverage-type: (string-ascii 32), ;; "grid-stability" or "weather-impact" or "combined"
    status: (string-ascii 16), ;; "active", "expired", "cancelled", "claimed"
    risk-parameters: {
      location-risk-factor: uint,
      equipment-type: (string-ascii 32),
      generation-capacity: uint, ;; In kW * 100 for precision
      expected-output: uint ;; Expected daily output in kWh * 100
    },
    premium-payment-schedule: (list 12 uint), ;; Monthly premium amounts
    next-payment-due: uint
  }
)

;; Claim records and processing
(define-map compensation-claims
  { claim-id: uint }
  {
    policy-id: uint,
    claimant: principal,
    claim-timestamp: uint,
    trigger-event-type: (string-ascii 32),
    trigger-severity: uint,
    oracle-data-timestamp: uint,
    compensation-amount: uint,
    claim-status: (string-ascii 16), ;; "pending", "approved", "rejected", "paid"
    auto-approved: bool,
    processing-notes: (string-ascii 256)
  }
)

;; Premium payment tracking
(define-map premium-payments
  { policy-id: uint, payment-sequence: uint }
  {
    payment-amount: uint,
    payment-timestamp: uint,
    payment-status: (string-ascii 16), ;; "paid", "overdue", "grace-period"
    late-fee-applied: uint
  }
)

;; Policy holder statistics and history
(define-map policy-holder-stats
  { holder-address: principal }
  {
    total-policies: uint,
    active-policies: uint,
    total-premiums-paid: uint,
    total-compensation-received: uint,
    claim-history: (list 20 uint), ;; List of claim IDs
    risk-score: uint, ;; 0-10000 scale
    last-policy-date: uint
  }
)

;; Daily claim tracking for rate limiting
(define-map daily-claim-counts
  { policy-id: uint, date: uint }
  { claim-count: uint }
)

;; Risk assessment parameters for different energy types
(define-map risk-profiles
  { equipment-type: (string-ascii 32) }
  {
    base-risk-score: uint,
    weather-sensitivity: uint, ;; 0-100 scale
    grid-dependency: uint, ;; 0-100 scale
    maintenance-factor: uint,
    technology-maturity: uint
  }
)

;; === PUBLIC FUNCTIONS ===

;; Create a new insurance policy
(define-public (create-policy 
  (coverage-amount uint) 
  (coverage-type (string-ascii 32))
  (equipment-type (string-ascii 32))
  (generation-capacity uint)
  (expected-output uint)
  (location-risk-factor uint))
  (let (
    (policy-id (+ (var-get policy-counter) u1))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    (policy-duration (* u30 u86400)) ;; 30 days default
    (premium-amount (calculate-premium coverage-amount equipment-type location-risk-factor))
  )
    ;; Validate input parameters
    (asserts! (> coverage-amount u0) (err ERR_INVALID_COVERAGE))
    (asserts! (<= coverage-amount MAX_COVERAGE_AMOUNT) (err ERR_INVALID_COVERAGE))
    (asserts! (>= premium-amount MIN_PREMIUM_AMOUNT) (err ERR_INVALID_PREMIUM))
    
    ;; Transfer initial premium from policy holder
    (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
    
    ;; Create policy record
    (map-set insurance-policies
      { policy-id: policy-id }
      {
        policy-holder: tx-sender,
        coverage-amount: coverage-amount,
        premium-amount: premium-amount,
        start-time: current-time,
        end-time: (+ current-time policy-duration),
        coverage-type: coverage-type,
        status: "active",
        risk-parameters: {
          location-risk-factor: location-risk-factor,
          equipment-type: equipment-type,
          generation-capacity: generation-capacity,
          expected-output: expected-output
        },
        premium-payment-schedule: (list premium-amount),
        next-payment-due: (+ current-time u2592000) ;; 30 days
      }
    )
    
    ;; Update counters and statistics
    (var-set policy-counter policy-id)
    (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) premium-amount))
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium-amount))
    
    ;; Update policy holder statistics
    (update-policy-holder-stats tx-sender policy-id premium-amount)
    
    ;; Record premium payment
    (map-set premium-payments
      { policy-id: policy-id, payment-sequence: u1 }
      {
        payment-amount: premium-amount,
        payment-timestamp: current-time,
        payment-status: "paid",
        late-fee-applied: u0
      }
    )
    
    (ok policy-id)
  )
)

;; Submit a compensation claim based on oracle trigger
(define-public (submit-claim (policy-id uint) (trigger-event-type (string-ascii 32)) (oracle-timestamp uint))
  (let (
    (policy-info (unwrap! (map-get? insurance-policies { policy-id: policy-id }) (err ERR_POLICY_NOT_FOUND)))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    (claim-id (+ (var-get claim-counter) u1))
    (daily-date (/ current-time u86400)) ;; Convert to days since epoch
    (daily-claims (default-to u0 (get claim-count (map-get? daily-claim-counts { policy-id: policy-id, date: daily-date }))))
  )
    ;; Verify policy holder authorization
    (asserts! (is-eq tx-sender (get policy-holder policy-info)) (err ERR_UNAUTHORIZED))
    ;; Check policy is active and not expired
    (asserts! (is-eq (get status policy-info) "active") (err ERR_POLICY_INACTIVE))
    (asserts! (> (get end-time policy-info) current-time) (err ERR_POLICY_EXPIRED))
    ;; Check daily claim limits
    (asserts! (< daily-claims MAXIMUM_DAILY_CLAIMS) (err ERR_ALREADY_CLAIMED))
    
    ;; Get oracle data to validate trigger conditions
    (let (
      (trigger-severity (get-trigger-severity trigger-event-type oracle-timestamp))
      (compensation-amount (calculate-compensation-amount policy-id trigger-severity))
      (auto-approved (is-auto-approvable trigger-severity))
    )
      ;; Verify trigger meets minimum thresholds
      (asserts! (is-eligible-for-compensation trigger-event-type trigger-severity) (err ERR_CLAIM_NOT_ELIGIBLE))
      
      ;; Create claim record
      (map-set compensation-claims
        { claim-id: claim-id }
        {
          policy-id: policy-id,
          claimant: tx-sender,
          claim-timestamp: current-time,
          trigger-event-type: trigger-event-type,
          trigger-severity: trigger-severity,
          oracle-data-timestamp: oracle-timestamp,
          compensation-amount: compensation-amount,
          claim-status: (if auto-approved "approved" "pending"),
          auto-approved: auto-approved,
          processing-notes: "claim-submitted"
        }
      )
      
      ;; Update counters
      (var-set claim-counter claim-id)
      
      ;; Update daily claim count
      (map-set daily-claim-counts
        { policy-id: policy-id, date: daily-date }
        { claim-count: (+ daily-claims u1) }
      )
      
      ;; If auto-approved, process payout immediately
      (if auto-approved
        (begin
          (try! (process-claim-payout claim-id))
          (ok { claim-id: claim-id, status: "auto-approved-and-paid", amount: compensation-amount })
        )
        (ok { claim-id: claim-id, status: "submitted-for-review", amount: compensation-amount })
      )
    )
  )
)

;; Process approved claim payout
(define-public (process-claim-payout (claim-id uint))
  (let (
    (claim-info (unwrap! (map-get? compensation-claims { claim-id: claim-id }) (err ERR_CLAIM_NOT_ELIGIBLE)))
    (current-pool-balance (var-get insurance-pool-balance))
    (payout-amount (get compensation-amount claim-info))
  )
    ;; Verify claim is approved and not already paid
    (asserts! (is-eq (get claim-status claim-info) "approved") (err ERR_UNAUTHORIZED))
    ;; Check sufficient pool balance
    (asserts! (>= current-pool-balance payout-amount) (err ERR_INSUFFICIENT_FUNDS))
    
    ;; Transfer compensation to claimant
    (try! (as-contract (stx-transfer? payout-amount tx-sender (get claimant claim-info))))
    
    ;; Update claim status
    (map-set compensation-claims
      { claim-id: claim-id }
      (merge claim-info { claim-status: "paid" })
    )
    
    ;; Update pool balance and statistics
    (var-set insurance-pool-balance (- current-pool-balance payout-amount))
    (var-set total-payouts-made (+ (var-get total-payouts-made) payout-amount))
    
    ;; Update policy holder statistics
    (update-compensation-stats (get claimant claim-info) payout-amount)
    
    (ok payout-amount)
  )
)

;; Pay premium for existing policy
(define-public (pay-premium (policy-id uint) (payment-sequence uint))
  (let (
    (policy-info (unwrap! (map-get? insurance-policies { policy-id: policy-id }) (err ERR_POLICY_NOT_FOUND)))
    (premium-amount (get premium-amount policy-info))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    ;; Verify policy holder
    (asserts! (is-eq tx-sender (get policy-holder policy-info)) (err ERR_UNAUTHORIZED))
    
    ;; Transfer premium payment
    (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
    
    ;; Record payment
    (map-set premium-payments
      { policy-id: policy-id, payment-sequence: payment-sequence }
      {
        payment-amount: premium-amount,
        payment-timestamp: current-time,
        payment-status: "paid",
        late-fee-applied: u0
      }
    )
    
    ;; Update pool balance
    (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) premium-amount))
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium-amount))
    
    (ok true)
  )
)

;; Emergency function for pool management
(define-public (emergency-pool-management (action (string-ascii 32)) (amount uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    
    (if (is-eq action "add-funds")
      (begin
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) amount))
        (ok true)
      )
      (if (is-eq action "emergency-mode")
        (begin
          (var-set emergency-mode true)
          (ok true)
        )
        (err ERR_UNAUTHORIZED)
      )
    )
  )
)

;; === READ-ONLY FUNCTIONS ===

;; Get policy information
(define-read-only (get-policy-info (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

;; Get claim information
(define-read-only (get-claim-info (claim-id uint))
  (map-get? compensation-claims { claim-id: claim-id })
)

;; Get policy holder statistics
(define-read-only (get-policy-holder-stats (holder-address principal))
  (map-get? policy-holder-stats { holder-address: holder-address })
)

;; Check if policy is eligible for coverage
(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-info (let (
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    )
      (and
        (is-eq (get status policy-info) "active")
        (> (get end-time policy-info) current-time)
      )
    )
    false
  )
)

;; Get current system statistics
(define-read-only (get-system-stats)
  {
    total-policies: (var-get policy-counter),
    total-claims: (var-get claim-counter),
    pool-balance: (var-get insurance-pool-balance),
    total-premiums: (var-get total-premiums-collected),
    total-payouts: (var-get total-payouts-made),
    emergency-mode: (var-get emergency-mode)
  }
)

;; === PRIVATE FUNCTIONS ===

;; Calculate premium based on risk factors
(define-private (calculate-premium (coverage-amount uint) (equipment-type (string-ascii 32)) (location-risk-factor uint))
  (let (
    (base-premium (* coverage-amount u5)) ;; 0.5% base rate
    (risk-multiplier (+ u100 location-risk-factor)) ;; Add location risk
    (equipment-risk (get-equipment-risk-factor equipment-type))
  )
    (/ (* base-premium risk-multiplier equipment-risk) u10000)
  )
)

;; Get equipment-specific risk factor
(define-private (get-equipment-risk-factor (equipment-type (string-ascii 32)))
  (if (is-eq equipment-type "solar")
    u120 ;; 20% higher risk
    (if (is-eq equipment-type "wind")
      u150 ;; 50% higher risk
      u100 ;; Standard risk
    )
  )
)

;; Calculate compensation amount based on trigger severity
(define-private (calculate-compensation-amount (policy-id uint) (trigger-severity uint))
  (let (
    (policy-info (unwrap-panic (map-get? insurance-policies { policy-id: policy-id })))
    (max-coverage (get coverage-amount policy-info))
    (severity-factor (if (> trigger-severity u100) u100 trigger-severity)) ;; Cap at 100%
  )
    (/ (* max-coverage severity-factor) u100)
  )
)

;; Get trigger severity from oracle data (simplified)
(define-private (get-trigger-severity (trigger-type (string-ascii 32)) (timestamp uint))
  ;; In production, this would call the oracle contract
  ;; Returning mock values for demonstration
  (if (is-eq trigger-type "grid-instability")
    u75
    (if (is-eq trigger-type "weather-impact")
      u60
      u0
    )
  )
)

;; Check if trigger is eligible for compensation
(define-private (is-eligible-for-compensation (trigger-type (string-ascii 32)) (severity uint))
  (if (is-eq trigger-type "grid-instability")
    (>= severity u50) ;; Minimum 50% severity for grid issues
    (if (is-eq trigger-type "weather-impact")
      (>= severity u40) ;; Minimum 40% severity for weather
      false
    )
  )
)

;; Check if claim should be auto-approved
(define-private (is-auto-approvable (severity uint))
  (>= severity u80) ;; Auto-approve claims with 80%+ severity
)

;; Update policy holder statistics
(define-private (update-policy-holder-stats (holder principal) (policy-id uint) (premium-paid uint))
  (let (
    (current-stats (default-to 
      {
        total-policies: u0,
        active-policies: u0,
        total-premiums-paid: u0,
        total-compensation-received: u0,
        claim-history: (list ),
        risk-score: u5000,
        last-policy-date: u0
      }
      (map-get? policy-holder-stats { holder-address: holder })))
  )
    (map-set policy-holder-stats
      { holder-address: holder }
      (merge current-stats {
        total-policies: (+ (get total-policies current-stats) u1),
        active-policies: (+ (get active-policies current-stats) u1),
        total-premiums-paid: (+ (get total-premiums-paid current-stats) premium-paid),
        last-policy-date: (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1)))
      })
    )
  )
)

;; Update compensation statistics
(define-private (update-compensation-stats (holder principal) (compensation-amount uint))
  (let (
    (current-stats (unwrap-panic (map-get? policy-holder-stats { holder-address: holder })))
  )
    (map-set policy-holder-stats
      { holder-address: holder }
      (merge current-stats {
        total-compensation-received: (+ (get total-compensation-received current-stats) compensation-amount)
      })
    )
  )
)

