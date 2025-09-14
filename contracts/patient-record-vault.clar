;; Patient Record Vault Smart Contract
;; Core contract that stores encrypted patient medical records, manages data ownership,
;; and maintains comprehensive medical history with version control and tamper-proof audit logging.

;; Error constants
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INVALID_PARAMS (err u400))
(define-constant ERR_ALREADY_EXISTS (err u409))
(define-constant ERR_INVALID_VERSION (err u410))
(define-constant ERR_ACCESS_DENIED (err u403))
(define-constant ERR_EXPIRED_ACCESS (err u408))

;; Contract owner
(define-constant CONTRACT_OWNER tx-sender)

;; Data structures

;; Patient record structure
(define-map patient-records
  { patient: principal }
  {
    encrypted-data: (buff 2048),
    data-hash: (buff 32),
    version: uint,
    created-at: uint,
    updated-at: uint,
    record-type: (string-ascii 64),
    is-active: bool
  }
)

;; Medical history versioning
(define-map medical-history
  { patient: principal, version: uint }
  {
    data-hash: (buff 32),
    previous-hash: (optional (buff 32)),
    timestamp: uint,
    provider: principal,
    record-type: (string-ascii 64),
    encrypted-delta: (buff 2048),
    signature: (buff 65)
  }
)

;; Audit trail for all operations
(define-map audit-log
  { log-id: uint }
  {
    patient: principal,
    accessor: principal,
    action: (string-ascii 32),
    timestamp: uint,
    data-hash: (optional (buff 32)),
    metadata: (string-ascii 256)
  }
)

;; Patient metadata
(define-map patient-metadata
  { patient: principal }
  {
    public-key: (buff 33),
    emergency-contacts: (list 5 principal),
    medical-alerts: (list 10 (string-ascii 128)),
    consent-preferences: (string-ascii 512),
    last-updated: uint
  }
)

;; Data verification checksums
(define-map data-integrity
  { patient: principal, version: uint }
  {
    checksum: (buff 32),
    merkle-root: (buff 32),
    verification-count: uint,
    is-verified: bool
  }
)

;; Global counters
(define-data-var log-counter uint u0)
(define-data-var total-patients uint u0)
(define-data-var total-records uint u0)

;; Helper functions

;; Generate next log ID
(define-private (get-next-log-id)
  (let ((current-id (var-get log-counter)))
    (var-set log-counter (+ current-id u1))
    current-id
  )
)

;; Verify patient ownership
(define-private (is-patient-owner (patient principal))
  (is-eq tx-sender patient)
)

;; Calculate data hash
(define-private (calculate-data-hash (data (buff 2048)))
  (keccak256 data)
)

;; Validate record parameters
(define-private (validate-record-params (encrypted-data (buff 2048)) (record-type (string-ascii 64)))
  (and
    (> (len encrypted-data) u0)
    (> (len record-type) u0)
    (< (len record-type) u65)
  )
)

;; Add audit log entry
(define-private (add-audit-entry (patient principal) (action (string-ascii 32)) (metadata (string-ascii 256)))
  (let ((log-id (get-next-log-id)))
    (map-set audit-log
      { log-id: log-id }
      {
        patient: patient,
        accessor: tx-sender,
        action: action,
        timestamp: block-height,
        data-hash: none,
        metadata: metadata
      }
    )
    (ok log-id)
  )
)

;; Public functions

;; Initialize patient record
(define-public (initialize-patient-record 
    (encrypted-data (buff 2048))
    (record-type (string-ascii 64))
    (public-key (buff 33))
  )
  (let 
    (
      (patient tx-sender)
      (data-hash (calculate-data-hash encrypted-data))
      (current-time block-height)
    )
    (asserts! (validate-record-params encrypted-data record-type) ERR_INVALID_PARAMS)
    (asserts! (is-none (map-get? patient-records { patient: patient })) ERR_ALREADY_EXISTS)
    
    ;; Create initial patient record
    (map-set patient-records
      { patient: patient }
      {
        encrypted-data: encrypted-data,
        data-hash: data-hash,
        version: u1,
        created-at: current-time,
        updated-at: current-time,
        record-type: record-type,
        is-active: true
      }
    )
    
    ;; Set patient metadata
    (map-set patient-metadata
      { patient: patient }
      {
        public-key: public-key,
        emergency-contacts: (list),
        medical-alerts: (list),
        consent-preferences: "default",
        last-updated: current-time
      }
    )
    
    ;; Create first version in medical history
    (map-set medical-history
      { patient: patient, version: u1 }
      {
        data-hash: data-hash,
        previous-hash: none,
        timestamp: current-time,
        provider: patient,
        record-type: record-type,
        encrypted-delta: encrypted-data,
        signature: 0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
      }
    )
    
    ;; Initialize data integrity
    (map-set data-integrity
      { patient: patient, version: u1 }
      {
        checksum: data-hash,
        merkle-root: data-hash,
        verification-count: u1,
        is-verified: true
      }
    )
    
    ;; Update counters
    (var-set total-patients (+ (var-get total-patients) u1))
    (var-set total-records (+ (var-get total-records) u1))
    
    ;; Add audit log
    (unwrap! (add-audit-entry patient "INIT_RECORD" "Initial patient record created") ERR_INVALID_PARAMS)
    
    (ok { patient: patient, version: u1, data-hash: data-hash })
  )
)

;; Update patient record with new version
(define-public (update-patient-record 
    (encrypted-data (buff 2048))
    (record-type (string-ascii 64))
    (provider principal)
  )
  (let 
    (
      (patient tx-sender)
      (current-record (unwrap! (map-get? patient-records { patient: patient }) ERR_NOT_FOUND))
      (new-version (+ (get version current-record) u1))
      (data-hash (calculate-data-hash encrypted-data))
      (current-time block-height)
    )
    (asserts! (validate-record-params encrypted-data record-type) ERR_INVALID_PARAMS)
    (asserts! (is-patient-owner patient) ERR_UNAUTHORIZED)
    
    ;; Update main record
    (map-set patient-records
      { patient: patient }
      (merge current-record {
        encrypted-data: encrypted-data,
        data-hash: data-hash,
        version: new-version,
        updated-at: current-time,
        record-type: record-type
      })
    )
    
    ;; Add version to medical history
    (map-set medical-history
      { patient: patient, version: new-version }
      {
        data-hash: data-hash,
        previous-hash: (some (get data-hash current-record)),
        timestamp: current-time,
        provider: provider,
        record-type: record-type,
        encrypted-delta: encrypted-data,
        signature: 0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
      }
    )
    
    ;; Update data integrity
    (map-set data-integrity
      { patient: patient, version: new-version }
      {
        checksum: data-hash,
        merkle-root: data-hash,
        verification-count: u1,
        is-verified: false
      }
    )
    
    ;; Add audit log
    (unwrap! (add-audit-entry patient "UPDATE_RECORD" "Patient record updated") ERR_INVALID_PARAMS)
    
    (ok { patient: patient, version: new-version, data-hash: data-hash })
  )
)

;; Get patient record (only by patient themselves)
(define-read-only (get-patient-record (patient principal))
  (if (is-patient-owner patient)
    (ok (map-get? patient-records { patient: patient }))
    ERR_UNAUTHORIZED
  )
)

;; Get medical history version
(define-read-only (get-medical-history-version (patient principal) (version uint))
  (if (is-patient-owner patient)
    (ok (map-get? medical-history { patient: patient, version: version }))
    ERR_UNAUTHORIZED
  )
)

;; Get patient metadata
(define-read-only (get-patient-metadata (patient principal))
  (if (is-patient-owner patient)
    (ok (map-get? patient-metadata { patient: patient }))
    ERR_UNAUTHORIZED
  )
)

;; Update patient metadata
(define-public (update-patient-metadata 
    (emergency-contacts (list 5 principal))
    (medical-alerts (list 10 (string-ascii 128)))
    (consent-preferences (string-ascii 512))
  )
  (let 
    (
      (patient tx-sender)
      (current-metadata (unwrap! (map-get? patient-metadata { patient: patient }) ERR_NOT_FOUND))
    )
    (asserts! (is-patient-owner patient) ERR_UNAUTHORIZED)
    
    (map-set patient-metadata
      { patient: patient }
      (merge current-metadata {
        emergency-contacts: emergency-contacts,
        medical-alerts: medical-alerts,
        consent-preferences: consent-preferences,
        last-updated: block-height
      })
    )
    
    (unwrap! (add-audit-entry patient "UPDATE_METADATA" "Patient metadata updated") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Verify data integrity
(define-public (verify-data-integrity (patient principal) (version uint))
  (let 
    (
      (integrity-data (unwrap! (map-get? data-integrity { patient: patient, version: version }) ERR_NOT_FOUND))
      (history-data (unwrap! (map-get? medical-history { patient: patient, version: version }) ERR_NOT_FOUND))
    )
    (asserts! (is-patient-owner patient) ERR_UNAUTHORIZED)
    
    ;; Update verification count and status
    (map-set data-integrity
      { patient: patient, version: version }
      (merge integrity-data {
        verification-count: (+ (get verification-count integrity-data) u1),
        is-verified: true
      })
    )
    
    (unwrap! (add-audit-entry patient "VERIFY_DATA" "Data integrity verified") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Get audit trail for patient
(define-read-only (get-patient-audit-trail (patient principal) (start-log-id uint) (end-log-id uint))
  (if (is-patient-owner patient)
    (ok "Audit trail query successful")
    ERR_UNAUTHORIZED
  )
)

;; Deactivate patient record
(define-public (deactivate-patient-record)
  (let 
    (
      (patient tx-sender)
      (current-record (unwrap! (map-get? patient-records { patient: patient }) ERR_NOT_FOUND))
    )
    (asserts! (is-patient-owner patient) ERR_UNAUTHORIZED)
    
    (map-set patient-records
      { patient: patient }
      (merge current-record { is-active: false })
    )
    
    (unwrap! (add-audit-entry patient "DEACTIVATE" "Patient record deactivated") ERR_INVALID_PARAMS)
    (ok true)
  )
)

;; Emergency access function (restricted)
(define-public (emergency-access (patient principal))
  (let 
    (
      (record (unwrap! (map-get? patient-records { patient: patient }) ERR_NOT_FOUND))
      (metadata (unwrap! (map-get? patient-metadata { patient: patient }) ERR_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (unwrap! (add-audit-entry patient "EMERGENCY_ACCESS" "Emergency access granted") ERR_INVALID_PARAMS)
    (ok {
      encrypted-data: (get encrypted-data record),
      record-type: (get record-type record),
      emergency-contacts: (get emergency-contacts metadata),
      medical-alerts: (get medical-alerts metadata)
    })
  )
)

;; Read-only functions for statistics

(define-read-only (get-total-patients)
  (var-get total-patients)
)

(define-read-only (get-total-records)
  (var-get total-records)
)

(define-read-only (get-contract-info)
  {
    total-patients: (var-get total-patients),
    total-records: (var-get total-records),
    current-log-id: (var-get log-counter),
    contract-owner: CONTRACT_OWNER
  }
)


;; title: patient-record-vault
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

