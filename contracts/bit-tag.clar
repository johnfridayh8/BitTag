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