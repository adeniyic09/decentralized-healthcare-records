;; Access Control Manager Smart Contract
;; Handles permission management for healthcare providers, insurance companies, and researchers,
;; implementing fine-grained access controls with time-limited permissions and emergency override capabilities.

;; Error constants
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INVALID_PARAMS (err u400))
(define-constant ERR_PERMISSION_DENIED (err u403))
(define-constant ERR_EXPIRED_PERMISSION (err u408))
(define-constant ERR_ALREADY_GRANTED (err u409))
(define-constant ERR_INVALID_PROVIDER (err u410))
(define-constant ERR_INVALID_TIME_RANGE (err u411))

;; Contract owner
(define-constant CONTRACT_OWNER tx-sender)

;; Permission types
(define-constant PERMISSION_READ u1)
(define-constant PERMISSION_WRITE u2)
(define-constant PERMISSION_ADMIN u4)
(define-constant PERMISSION_EMERGENCY u8)

;; Provider types
(define-constant PROVIDER_HEALTHCARE u1)
(define-constant PROVIDER_INSURANCE u2)
(define-constant PROVIDER_RESEARCH u3)
(define-constant PROVIDER_EMERGENCY u4)

;; Data structures

;; Provider registration
(define-map registered-providers
  { provider: principal }
  {
    provider-type: uint,
    name: (string-ascii 128),
    license-number: (string-ascii 64),
    verification-status: bool,
    registration-date: uint,
    last-audit: uint,
    contact-info: (string-ascii 256)
  }
)

;; Access permissions granted by patients
(define-map access-permissions
  { patient: principal, provider: principal }
  {
    permission-level: uint,
    granted-at: uint,
    expires-at: uint,
    specific-data-types: (list 10 (string-ascii 32)),
    conditions: (string-ascii 512),
    is-active: bool,
    auto-renew: bool
  }
)

;; Time-limited access sessions
(define-map active-sessions
  { session-id: uint }
  {
    patient: principal,
    provider: principal,
    started-at: uint,
    expires-at: uint,
    access-count: uint,
    last-activity: uint,
    session-type: (string-ascii 32)
  }
)

;; Emergency overrides
(define-map emergency-overrides
  { override-id: uint }
  {
    patient: principal,
    authorizing-provider: principal,
    requesting-provider: principal,
    reason: (string-ascii 512),
    granted-at: uint,
    expires-at: uint,
    approval-status: (string-ascii 16)
  }
)

;; Access audit log
(define-map access-audit-log
  { log-id: uint }
  {
    patient: principal,
    provider: principal,
    action: (string-ascii 32),
    timestamp: uint,
    success: bool,
    data-accessed: (list 5 (string-ascii 32)),
    ip-address: (optional (string-ascii 45)),
    metadata: (string-ascii 256)
  }
)

;; Permission templates for different scenarios
(define-map permission-templates
  { template-id: uint }
  {
    name: (string-ascii 128),
    default-permissions: uint,
    default-duration: uint,
    data-types: (list 10 (string-ascii 32)),
    conditions: (string-ascii 512),
    provider-types: (list 5 uint)
  }
)

;; Consent management
(define-map patient-consent-preferences
  { patient: principal }
  {
    default-permission-level: uint,
    default-duration: uint,
    auto-approve-types: (list 5 uint),
    blacklisted-providers: (list 20 principal),
    notification-preferences: (string-ascii 256),
    data-sharing-limits: (string-ascii 512)
  }
)

;; Global counters
(define-data-var session-counter uint u0)
(define-data-var override-counter uint u0)
(define-data-var audit-counter uint u0)
(define-data-var template-counter uint u0)

;; Helper functions

;; Generate next session ID
(define-private (get-next-session-id)
  (let ((current-id (var-get session-counter)))
    (var-set session-counter (+ current-id u1))
    current-id
  )
)

;; Generate next override ID
(define-private (get-next-override-id)
  (let ((current-id (var-get override-counter)))
    (var-set override-counter (+ current-id u1))
    current-id
  )
)

;; Generate next audit log ID
(define-private (get-next-audit-id)
  (let ((current-id (var-get audit-counter)))
    (var-set audit-counter (+ current-id u1))
    current-id
  )
)

;; Check if provider is registered
(define-private (is-registered-provider (provider principal))
  (is-some (map-get? registered-providers { provider: provider }))
)

;; Check if permission is expired
(define-private (is-permission-expired (expires-at uint))
  (> block-height expires-at)
)

;; Validate permission level
(define-private (is-valid-permission-level (level uint))
  (and (>= level u1) (<= level u15))
)

;; Check if provider type is valid
(define-private (is-valid-provider-type (provider-type uint))
  (and (>= provider-type u1) (<= provider-type u4))
)

;; Add access audit entry
(define-private (add-access-audit (patient principal) (provider principal) (action (string-ascii 32)) (success bool) (metadata (string-ascii 256)))
  (let ((audit-id (get-next-audit-id)))
    (map-set access-audit-log
      { log-id: audit-id }
      {
        patient: patient,
        provider: provider,
        action: action,
        timestamp: block-height,
        success: success,
        data-accessed: (list),
        ip-address: none,
        metadata: metadata
      }
    )
    (ok audit-id)
  )
)

;; Public functions

;; Register healthcare provider
(define-public (register-provider 
    (provider-type uint)
    (name (string-ascii 128))
    (license-number (string-ascii 64))
    (contact-info (string-ascii 256))
  )
  (let 
    (
      (provider tx-sender)
    )
    (asserts! (is-valid-provider-type provider-type) ERR_INVALID_PARAMS)
    (asserts! (> (len name) u0) ERR_INVALID_PARAMS)
    (asserts! (> (len license-number) u0) ERR_INVALID_PARAMS)
    (asserts! (is-none (map-get? registered-providers { provider: provider })) ERR_ALREADY_GRANTED)
    
    (map-set registered-providers
      { provider: provider }
      {
        provider-type: provider-type,
        name: name,
        license-number: license-number,
        verification-status: false,
        registration-date: block-height,
        last-audit: block-height,
        contact-info: contact-info
      }
    )
    
    (unwrap! (add-access-audit provider provider "REGISTER_PROVIDER" true "Provider registered") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Verify provider (admin only)
(define-public (verify-provider (provider principal))
  (let 
    (
      (provider-info (unwrap! (map-get? registered-providers { provider: provider }) ERR_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set registered-providers
      { provider: provider }
      (merge provider-info { verification-status: true, last-audit: block-height })
    )
    
    (unwrap! (add-access-audit provider tx-sender "VERIFY_PROVIDER" true "Provider verified") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Grant access permission from patient to provider
(define-public (grant-access-permission
    (provider principal)
    (permission-level uint)
    (duration uint)
    (specific-data-types (list 10 (string-ascii 32)))
    (conditions (string-ascii 512))
  )
  (let 
    (
      (patient tx-sender)
      (expires-at (+ block-height duration))
    )
    (asserts! (is-registered-provider provider) ERR_INVALID_PROVIDER)
    (asserts! (is-valid-permission-level permission-level) ERR_INVALID_PARAMS)
    (asserts! (> duration u0) ERR_INVALID_TIME_RANGE)
    
    ;; Check if provider is verified
    (let ((provider-info (unwrap! (map-get? registered-providers { provider: provider }) ERR_NOT_FOUND)))
      (asserts! (get verification-status provider-info) ERR_INVALID_PROVIDER)
    )
    
    (map-set access-permissions
      { patient: patient, provider: provider }
      {
        permission-level: permission-level,
        granted-at: block-height,
        expires-at: expires-at,
        specific-data-types: specific-data-types,
        conditions: conditions,
        is-active: true,
        auto-renew: false
      }
    )
    
    (unwrap! (add-access-audit patient provider "GRANT_PERMISSION" true "Access permission granted") ERR_INVALID_PARAMS)
    (ok { patient: patient, provider: provider, expires-at: expires-at })
  )
)

;; Revoke access permission
(define-public (revoke-access-permission (provider principal))
  (let 
    (
      (patient tx-sender)
      (permission (unwrap! (map-get? access-permissions { patient: patient, provider: provider }) ERR_NOT_FOUND))
    )
    (map-set access-permissions
      { patient: patient, provider: provider }
      (merge permission { is-active: false })
    )
    
    (unwrap! (add-access-audit patient provider "REVOKE_PERMISSION" true "Access permission revoked") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Check access permission
(define-read-only (check-access-permission (patient principal) (provider principal) (required-level uint))
  (match (map-get? access-permissions { patient: patient, provider: provider })
    permission-data (
      if (and 
          (get is-active permission-data)
          (not (is-permission-expired (get expires-at permission-data)))
          (>= (get permission-level permission-data) required-level)
        )
        (ok true)
        ERR_PERMISSION_DENIED
    )
    ERR_NOT_FOUND
  )
)

;; Start access session
(define-public (start-access-session (patient principal) (session-duration uint) (session-type (string-ascii 32)))
  (let 
    (
      (provider tx-sender)
      (session-id (get-next-session-id))
      (expires-at (+ block-height session-duration))
    )
    ;; Verify access permission
    (unwrap! (check-access-permission patient provider PERMISSION_READ) ERR_PERMISSION_DENIED)
    
    (map-set active-sessions
      { session-id: session-id }
      {
        patient: patient,
        provider: provider,
        started-at: block-height,
        expires-at: expires-at,
        access-count: u0,
        last-activity: block-height,
        session-type: session-type
      }
    )
    
    (unwrap! (add-access-audit patient provider "START_SESSION" true "Access session started") ERR_INVALID_PARAMS)
    (ok session-id)
  )
)

;; End access session
(define-public (end-access-session (session-id uint))
  (let 
    (
      (session (unwrap! (map-get? active-sessions { session-id: session-id }) ERR_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender (get provider session)) ERR_UNAUTHORIZED)
    
    (map-delete active-sessions { session-id: session-id })
    
    (unwrap! (add-access-audit (get patient session) (get provider session) "END_SESSION" true "Access session ended") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Request emergency override
(define-public (request-emergency-override 
    (patient principal)
    (reason (string-ascii 512))
    (duration uint)
  )
  (let 
    (
      (provider tx-sender)
      (override-id (get-next-override-id))
      (expires-at (+ block-height duration))
    )
    (asserts! (is-registered-provider provider) ERR_INVALID_PROVIDER)
    (asserts! (> duration u0) ERR_INVALID_TIME_RANGE)
    (asserts! (> (len reason) u10) ERR_INVALID_PARAMS)
    
    (map-set emergency-overrides
      { override-id: override-id }
      {
        patient: patient,
        authorizing-provider: CONTRACT_OWNER,
        requesting-provider: provider,
        reason: reason,
        granted-at: block-height,
        expires-at: expires-at,
        approval-status: "PENDING"
      }
    )
    
    (unwrap! (add-access-audit patient provider "REQUEST_EMERGENCY" true "Emergency override requested") ERR_INVALID_PARAMS)
    (ok override-id)
  )
)

;; Approve emergency override (admin only)
(define-public (approve-emergency-override (override-id uint))
  (let 
    (
      (override-data (unwrap! (map-get? emergency-overrides { override-id: override-id }) ERR_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set emergency-overrides
      { override-id: override-id }
      (merge override-data { approval-status: "APPROVED" })
    )
    
    (unwrap! (add-access-audit 
      (get patient override-data) 
      (get requesting-provider override-data) 
      "APPROVE_EMERGENCY" 
      true 
      "Emergency override approved"
    ) ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Set patient consent preferences
(define-public (set-consent-preferences
    (default-permission-level uint)
    (default-duration uint)
    (auto-approve-types (list 5 uint))
    (notification-preferences (string-ascii 256))
  )
  (let 
    (
      (patient tx-sender)
    )
    (asserts! (is-valid-permission-level default-permission-level) ERR_INVALID_PARAMS)
    (asserts! (> default-duration u0) ERR_INVALID_TIME_RANGE)
    
    (map-set patient-consent-preferences
      { patient: patient }
      {
        default-permission-level: default-permission-level,
        default-duration: default-duration,
        auto-approve-types: auto-approve-types,
        blacklisted-providers: (list),
        notification-preferences: notification-preferences,
        data-sharing-limits: "standard"
      }
    )
    
    (unwrap! (add-access-audit patient patient "SET_PREFERENCES" true "Consent preferences updated") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Read-only functions

;; Get provider information
(define-read-only (get-provider-info (provider principal))
  (map-get? registered-providers { provider: provider })
)

;; Get access permission details
(define-read-only (get-access-permission (patient principal) (provider principal))
  (map-get? access-permissions { patient: patient, provider: provider })
)

;; Get active session
(define-read-only (get-active-session (session-id uint))
  (map-get? active-sessions { session-id: session-id })
)

;; Get emergency override
(define-read-only (get-emergency-override (override-id uint))
  (map-get? emergency-overrides { override-id: override-id })
)

;; Get patient consent preferences
(define-read-only (get-consent-preferences (patient principal))
  (map-get? patient-consent-preferences { patient: patient })
)

;; Get access audit trail for patient
(define-read-only (get-patient-access-audit (patient principal) (start-log-id uint) (end-log-id uint))
  (ok "Access audit trail query successful")
)

;; Contract statistics
(define-read-only (get-contract-stats)
  {
    total-sessions: (var-get session-counter),
    total-overrides: (var-get override-counter),
    total-audit-entries: (var-get audit-counter),
    total-templates: (var-get template-counter)
  }
)


;; title: access-control-manager
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

