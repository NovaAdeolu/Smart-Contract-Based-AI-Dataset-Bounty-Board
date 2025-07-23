(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-bounty (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-already-submitted (err u105))
(define-constant err-invalid-vote (err u106))
(define-constant err-bounty-expired (err u107))
(define-constant err-bounty-not-active (err u108))

(define-data-var next-bounty-id uint u1)
(define-data-var next-submission-id uint u1)
(define-data-var voting-period uint u1008)
(define-data-var min-validators uint u3)

(define-map bounties
  { bounty-id: uint }
  {
    creator: principal,
    title: (string-ascii 128),
    description: (string-ascii 512),
    reward: uint,
    deadline: uint,
    required-samples: uint,
    status: (string-ascii 16),
    created-at: uint
  }
)

(define-map submissions
  { submission-id: uint }
  {
    bounty-id: uint,
    contributor: principal,
    ipfs-hash: (string-ascii 64),
    sample-count: uint,
    status: (string-ascii 16),
    submitted-at: uint,
    validation-end: uint
  }
)

(define-map validators
  { validator: principal }
  { is-active: bool, reputation: uint }
)

(define-map votes
  { submission-id: uint, validator: principal }
  { vote: bool, voted-at: uint }
)

(define-map submission-votes
  { submission-id: uint }
  { yes-votes: uint, no-votes: uint, total-votes: uint }
)

(define-map bounty-funds
  { bounty-id: uint }
  { amount: uint }
)

(define-public (create-bounty 
  (title (string-ascii 128))
  (description (string-ascii 512))
  (required-samples uint)
  (deadline uint)
  (reward uint))
  (let
    (
      (bounty-id (var-get next-bounty-id))
      (current-block stacks-block-height)
    )
    (asserts! (> reward u0) err-invalid-bounty)
    (asserts! (> deadline current-block) err-invalid-bounty)
    (asserts! (> required-samples u0) err-invalid-bounty)
    
    (try! (stx-transfer? reward tx-sender (as-contract tx-sender)))
    
    (map-set bounties
      { bounty-id: bounty-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        reward: reward,
        deadline: deadline,
        required-samples: required-samples,
        status: "active",
        created-at: current-block
      }
    )
    
    (map-set bounty-funds
      { bounty-id: bounty-id }
      { amount: reward }
    )
    
    (var-set next-bounty-id (+ bounty-id u1))
    (ok bounty-id)
  )
)

(define-public (submit-dataset
  (bounty-id uint)
  (ipfs-hash (string-ascii 64))
  (sample-count uint))
  (let
    (
      (submission-id (var-get next-submission-id))
      (current-block stacks-block-height)
      (bounty (unwrap! (map-get? bounties { bounty-id: bounty-id }) err-not-found))
    )
    (asserts! (is-eq (get status bounty) "active") err-bounty-not-active)
    (asserts! (< current-block (get deadline bounty)) err-bounty-expired)
    (asserts! (>= sample-count (get required-samples bounty)) err-invalid-bounty)
    (asserts! (is-none (map-get? submissions { submission-id: submission-id })) err-already-submitted)
    
    (map-set submissions
      { submission-id: submission-id }
      {
        bounty-id: bounty-id,
        contributor: tx-sender,
        ipfs-hash: ipfs-hash,
        sample-count: sample-count,
        status: "pending",
        submitted-at: current-block,
        validation-end: (+ current-block (var-get voting-period))
      }
    )
    
    (map-set submission-votes
      { submission-id: submission-id }
      { yes-votes: u0, no-votes: u0, total-votes: u0 }
    )
    
    (var-set next-submission-id (+ submission-id u1))
    (ok submission-id)
  )
)

(define-public (register-validator)
  (begin
    (map-set validators
      { validator: tx-sender }
      { is-active: true, reputation: u100 }
    )
    (ok true)
  )
)

(define-public (vote-on-submission
  (submission-id uint)
  (vote bool))
  (let
    (
      (submission (unwrap! (map-get? submissions { submission-id: submission-id }) err-not-found))
      (validator-info (unwrap! (map-get? validators { validator: tx-sender }) err-unauthorized))
      (current-votes (unwrap! (map-get? submission-votes { submission-id: submission-id }) err-not-found))
      (current-block stacks-block-height)
    )
    (asserts! (get is-active validator-info) err-unauthorized)
    (asserts! (< current-block (get validation-end submission)) err-bounty-expired)
    (asserts! (is-none (map-get? votes { submission-id: submission-id, validator: tx-sender })) err-already-submitted)
    
    (map-set votes
      { submission-id: submission-id, validator: tx-sender }
      { vote: vote, voted-at: current-block }
    )
    
    (if vote
      (map-set submission-votes
        { submission-id: submission-id }
        {
          yes-votes: (+ (get yes-votes current-votes) u1),
          no-votes: (get no-votes current-votes),
          total-votes: (+ (get total-votes current-votes) u1)
        }
      )
      (map-set submission-votes
        { submission-id: submission-id }
        {
          yes-votes: (get yes-votes current-votes),
          no-votes: (+ (get no-votes current-votes) u1),
          total-votes: (+ (get total-votes current-votes) u1)
        }
      )
    )
    (ok true)
  )
)

(define-public (finalize-submission (submission-id uint))
  (let
    (
      (submission (unwrap! (map-get? submissions { submission-id: submission-id }) err-not-found))
      (vote-tally (unwrap! (map-get? submission-votes { submission-id: submission-id }) err-not-found))
      (bounty (unwrap! (map-get? bounties { bounty-id: (get bounty-id submission) }) err-not-found))
      (current-block stacks-block-height)
    )
    (asserts! (>= current-block (get validation-end submission)) err-invalid-vote)
    (asserts! (>= (get total-votes vote-tally) (var-get min-validators)) err-invalid-vote)
    
    (if (> (get yes-votes vote-tally) (get no-votes vote-tally))
      (begin
        (map-set submissions
          { submission-id: submission-id }
          (merge submission { status: "approved" })
        )
        (try! (as-contract (stx-transfer? (get reward bounty) tx-sender (get contributor submission))))
        (map-set bounties
          { bounty-id: (get bounty-id submission) }
          (merge bounty { status: "completed" })
        )
        (ok "approved")
      )
      (begin
        (map-set submissions
          { submission-id: submission-id }
          (merge submission { status: "rejected" })
        )
        (ok "rejected")
      )
    )
  )
)

(define-public (cancel-bounty (bounty-id uint))
  (let
    (
      (bounty (unwrap! (map-get? bounties { bounty-id: bounty-id }) err-not-found))
      (funds (unwrap! (map-get? bounty-funds { bounty-id: bounty-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender (get creator bounty)) err-unauthorized)
    (asserts! (is-eq (get status bounty) "active") err-bounty-not-active)
    
    (try! (as-contract (stx-transfer? (get amount funds) tx-sender (get creator bounty))))
    
    (map-set bounties
      { bounty-id: bounty-id }
      (merge bounty { status: "cancelled" })
    )
    (ok true)
  )
)

(define-read-only (get-bounty (bounty-id uint))
  (map-get? bounties { bounty-id: bounty-id })
)

(define-read-only (get-submission (submission-id uint))
  (map-get? submissions { submission-id: submission-id })
)

(define-read-only (get-submission-votes (submission-id uint))
  (map-get? submission-votes { submission-id: submission-id })
)

(define-read-only (get-validator (validator principal))
  (map-get? validators { validator: validator })
)

(define-read-only (get-vote (submission-id uint) (validator principal))
  (map-get? votes { submission-id: submission-id, validator: validator })
)

(define-read-only (get-contract-balance)
  (stx-get-balance (as-contract tx-sender))
)

(define-read-only (get-next-bounty-id)
  (var-get next-bounty-id)
)

(define-read-only (get-next-submission-id)
  (var-get next-submission-id)
)
