;; Title: BitTag - Bitcoin Payment Request Protocol
;; Summary: A decentralized payment tagging system for Bitcoin Layer 2 transactions
;; Description: BitTag enables users to create secure, time-bound payment requests
;;              on Stacks Layer 2, leveraging sBTC for seamless Bitcoin-native 
;;              transactions. Perfect for invoicing, bill splitting, and P2P payments
;;              with built-in expiration mechanics and state management.
;;
;; Network: Stacks Layer 2 / Bitcoin L2
;; Token: sBTC (Synthetic Bitcoin)

;; Error Constants
(define-constant ERR-TAG-EXISTS u100)
(define-constant ERR-NOT-PENDING u101)
(define-constant ERR-INSUFFICIENT-FUNDS u102)
(define-constant ERR-NOT-FOUND u103)
(define-constant ERR-UNAUTHORIZED u104)
(define-constant ERR-EXPIRED u105)
(define-constant ERR-INVALID-AMOUNT u106)
(define-constant ERR-EMPTY-MEMO u107)
(define-constant ERR-MAX-EXPIRATION-EXCEEDED u108)

;; State Constants
(define-constant STATE-PENDING "pending")
(define-constant STATE-PAID "paid")
(define-constant STATE-EXPIRED "expired")
(define-constant STATE-CANCELED "canceled")

;; Protocol Configuration
;; Official sBTC token contract on Stacks Layer 2
(define-constant SBTC-CONTRACT 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token)

;; Contract owner for administrative functions
(define-constant CONTRACT-OWNER tx-sender)

;; Maximum expiration time: 30 days in blocks (~10 min per block on Bitcoin)
(define-constant MAX-EXPIRATION-BLOCKS u4320)

;; Data Storage Maps

;; Primary storage for BitTag payment requests
(define-map pay-tags
  { id: uint }
  {
    creator: principal,
    recipient: principal,
    amount: uint,
    created-at: uint,
    expires-at: uint,
    memo: (optional (string-ascii 256)),
    state: (string-ascii 16),
    payment-tx: (optional (buff 32)),
  }
)

;; Index for quick lookup of tags by creator
(define-map tags-by-creator
  { creator: principal }
  { ids: (list 50 uint) }
)

;; Index for quick lookup of tags by recipient
(define-map tags-by-recipient
  { recipient: principal }
  { ids: (list 50 uint) }
)

;; State Variables

;; Auto-incrementing ID counter for unique BitTag identification
(define-data-var last-id uint u0)

;; Private Helper Functions

;; Add a new BitTag ID to a principal's tag list
(define-private (add-id-to-principal-list
    (user principal)
    (id uint)
  )
  (let (
      (current-list-data (default-to { ids: (list) } (map-get? tags-by-creator { creator: user })))
      (current-list (get ids current-list-data))
      (new-list (unwrap! (as-max-len? (append current-list id) u50) current-list))
    )
    (begin
      (map-set tags-by-creator { creator: user } { ids: new-list })
      new-list
    )
  )
)

;; Check if current block height exceeds expiration time
(define-private (is-expired (expires-at uint))
  (>= stacks-block-height expires-at)
)

;; Helper function for batch operations
(define-private (get-tag-or-none (id uint))
  (map-get? pay-tags { id: id })
)

;; Read-Only Functions

;; Get the current BitTag ID counter
(define-read-only (get-last-id)
  (ok (var-get last-id))
)

;; Retrieve details of a specific BitTag
(define-read-only (get-pay-tag (id uint))
  (match (map-get? pay-tags { id: id })
    entry (ok entry)
    (err ERR-NOT-FOUND)
  )
)

;; Get all BitTag IDs created by a specific principal
(define-read-only (get-creator-tags (creator principal))
  (match (map-get? tags-by-creator { creator: creator })
    entry (ok (get ids entry))
    (ok (list))
  )
)

;; Get all BitTag IDs where principal is the recipient  
(define-read-only (get-recipient-tags (recipient principal))
  (match (map-get? tags-by-recipient { recipient: recipient })
    entry (ok (get ids entry))
    (ok (list))
  )
)

;; Check if a BitTag has expired but hasn't been marked as expired
(define-read-only (check-tag-expired (id uint))
  (match (map-get? pay-tags { id: id })
    tag (if (and
        (is-eq (get state tag) STATE-PENDING)
        (is-expired (get expires-at tag))
      )
      (ok true)
      (ok false)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Public Transaction Functions

;; Create a new BitTag payment request
(define-public (create-pay-tag
    (amount uint)
    (expires-in uint)
    (memo (optional (string-ascii 256)))
  )
  (let (
      (new-id (+ (var-get last-id) u1))
      (expiration-height (+ stacks-block-height expires-in))
      (recipient tx-sender)
      ;; Create a clean memo value to avoid unchecked data warning
      (validated-memo (if (is-some memo)
        (let ((memo-str (unwrap-panic memo)))
          (if (and (> (len memo-str) u0) (<= (len memo-str) u256))
            (some memo-str)
            none
          )
        )
        none
      ))
    )
    (begin
      ;; Input validation
      (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
      (asserts! (<= expires-in MAX-EXPIRATION-BLOCKS)
        (err ERR-MAX-EXPIRATION-EXCEEDED)
      )
      (asserts! (<= amount u340282366920938463463374607431768211455)
        (err ERR-INVALID-AMOUNT)
      ) ;; Max uint check
      ;; Create new BitTag
      (var-set last-id new-id)
      (map-set pay-tags { id: new-id } {
        creator: tx-sender,
        recipient: recipient,
        amount: amount,
        created-at: stacks-block-height,
        expires-at: expiration-height,
        memo: validated-memo,
        state: STATE-PENDING,
        payment-tx: none,
      })
      ;; Update indexes
      (let ((creator-result (add-id-to-principal-list tx-sender new-id)))
        (if (not (is-eq recipient tx-sender))
          (let ((recipient-result (add-id-to-principal-list recipient new-id)))
            true
          )
          true
        )
      )
      ;; Emit creation event
      (print {
        event: "bittag-created",
        id: new-id,
        creator: tx-sender,
        amount: amount,
        expires-at: expiration-height,
      })
      (ok new-id)
    )
  )
)

;; Fulfill a BitTag payment request
(define-public (fulfill-pay-tag (id uint))
  (let (
      (tag (unwrap! (map-get? pay-tags { id: id }) (err ERR-NOT-FOUND)))
      (placeholder-tx-hash 0x)
      ;; Validate ID bounds
      (validated-id (if (and (> id u0) (<= id (var-get last-id)))
        id
        u0
      ))
    )
    (begin
      ;; Input validation
      (asserts! (> validated-id u0) (err ERR-NOT-FOUND))
      ;; Validate payment conditions
      (asserts! (is-eq (get state tag) STATE-PENDING) (err ERR-NOT-PENDING))
      (asserts! (< stacks-block-height (get expires-at tag)) (err ERR-EXPIRED))
      ;; Execute sBTC transfer on Bitcoin Layer 2
      (try! (contract-call? SBTC-CONTRACT transfer (get amount tag) tx-sender
        (get recipient tag) none
      ))
      ;; Update BitTag state to paid
      (map-set pay-tags { id: validated-id }
        (merge tag {
          state: STATE-PAID,
          payment-tx: none,
        })
      )
      ;; Emit payment completion event
      (print {
        event: "bittag-fulfilled",
        id: validated-id,
        payer: tx-sender,
        recipient: (get recipient tag),
        amount: (get amount tag),
        memo: (get memo tag),
      })
      (ok validated-id)
    )
  )
)

;; Cancel a pending BitTag (creator only)
(define-public (cancel-pay-tag (id-input uint))
  (let (
      ;; Validate ID bounds first
      (validated-id (if (and (> id-input u0) (<= id-input (var-get last-id)))
        id-input
        u0
      ))
      (tag (unwrap! (map-get? pay-tags { id: validated-id }) (err ERR-NOT-FOUND)))
    )
    (begin
      ;; Input validation
      (asserts! (> validated-id u0) (err ERR-NOT-FOUND))
      ;; Authorization check
      (asserts! (is-eq tx-sender (get creator tag)) (err ERR-UNAUTHORIZED))
      (asserts! (is-eq (get state tag) STATE-PENDING) (err ERR-NOT-PENDING))
      ;; Update state to canceled
      (map-set pay-tags { id: validated-id }
        (merge tag { state: STATE-CANCELED })
      )
      ;; Emit cancellation event
      (print {
        event: "bittag-canceled",
        id: validated-id,
        creator: tx-sender,
      })
      (ok validated-id)
    )
  )
)

;; Mark an expired BitTag as expired (callable by anyone)
(define-public (mark-expired (id-input uint))
  (let (
      ;; Validate ID bounds first
      (validated-id (if (and (> id-input u0) (<= id-input (var-get last-id)))
        id-input
        u0
      ))
      (tag (unwrap! (map-get? pay-tags { id: validated-id }) (err ERR-NOT-FOUND)))
    )
    (begin
      ;; Input validation
      (asserts! (> validated-id u0) (err ERR-NOT-FOUND))
      ;; Validate expiration conditions
      (asserts! (is-eq (get state tag) STATE-PENDING) (err ERR-NOT-PENDING))
      (asserts! (is-expired (get expires-at tag)) (err u107))
      ;; Update state to expired
      (map-set pay-tags { id: validated-id } (merge tag { state: STATE-EXPIRED }))
      ;; Emit expiration event
      (print {
        event: "bittag-expired",
        id: validated-id,
        expired-at: stacks-block-height,
      })
      (ok validated-id)
    )
  )
)

;; Batch retrieve multiple BitTags (optimized for UI applications)
(define-public (get-multiple-tags (ids (list 20 uint)))
  (ok (map get-tag-or-none ids))
)
