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
(define-constant err-low-reputation (err u109))

(define-data-var next-bounty-id uint u1)
(define-data-var next-submission-id uint u1)
(define-data-var voting-period uint u1008)
(define-data-var min-validators uint u3)
(define-data-var min-reputation uint u50)

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
  { is-active: bool, reputation: uint, total-votes: uint, correct-votes: uint }
)

(define-map contributor-stats
  { contributor: principal }
  { total-submissions: uint, approved-submissions: uint, reputation: uint }
)

(define-map submission-weights
  { submission-id: uint }
  { weighted-yes: uint, weighted-no: uint, total-weight: uint }
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
    
    (map-set submission-weights
      { submission-id: submission-id }
      { weighted-yes: u0, weighted-no: u0, total-weight: u0 }
    )
    
    (let
      ((contributor-data (default-to { total-submissions: u0, approved-submissions: u0, reputation: u100 }
                                     (map-get? contributor-stats { contributor: tx-sender }))))
      (map-set contributor-stats
        { contributor: tx-sender }
        (merge contributor-data { total-submissions: (+ (get total-submissions contributor-data) u1) })
      )
    )
    
    (var-set next-submission-id (+ submission-id u1))
    (ok submission-id)
  )
)

(define-public (register-validator)
  (begin
    (map-set validators
      { validator: tx-sender }
      { is-active: true, reputation: u100, total-votes: u0, correct-votes: u0 }
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
    (asserts! (>= (get reputation validator-info) (var-get min-reputation)) err-low-reputation)
    (asserts! (< current-block (get validation-end submission)) err-bounty-expired)
    (asserts! (is-none (map-get? votes { submission-id: submission-id, validator: tx-sender })) err-already-submitted)
    
    (map-set votes
      { submission-id: submission-id, validator: tx-sender }
      { vote: vote, voted-at: current-block }
    )
    
    (let
      ((validator-weight (get reputation validator-info))
       (current-weights (unwrap! (map-get? submission-weights { submission-id: submission-id }) err-not-found)))
      (if vote
        (begin
          (map-set submission-votes
            { submission-id: submission-id }
            {
              yes-votes: (+ (get yes-votes current-votes) u1),
              no-votes: (get no-votes current-votes),
              total-votes: (+ (get total-votes current-votes) u1)
            }
          )
          (map-set submission-weights
            { submission-id: submission-id }
            {
              weighted-yes: (+ (get weighted-yes current-weights) validator-weight),
              weighted-no: (get weighted-no current-weights),
              total-weight: (+ (get total-weight current-weights) validator-weight)
            }
          )
        )
        (begin
          (map-set submission-votes
            { submission-id: submission-id }
            {
              yes-votes: (get yes-votes current-votes),
              no-votes: (+ (get no-votes current-votes) u1),
              total-votes: (+ (get total-votes current-votes) u1)
            }
          )
          (map-set submission-weights
            { submission-id: submission-id }
            {
              weighted-yes: (get weighted-yes current-weights),
              weighted-no: (+ (get weighted-no current-weights) validator-weight),
              total-weight: (+ (get total-weight current-weights) validator-weight)
            }
          )
        )
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
    
    (let
      ((weights (unwrap! (map-get? submission-weights { submission-id: submission-id }) err-not-found))
       (is-approved (> (get weighted-yes weights) (get weighted-no weights)))
       (validator-update (update-validator-reputations submission-id is-approved)))
      (if is-approved
        (let
          ((transfer-result (try! (as-contract (stx-transfer? (get reward bounty) tx-sender (get contributor submission)))))
           (contributor-update (update-contributor-reputation (get contributor submission) true)))
          (map-set submissions
            { submission-id: submission-id }
            (merge submission { status: "approved" })
          )
          (map-set bounties
            { bounty-id: (get bounty-id submission) }
            (merge bounty { status: "completed" })
          )
          (ok "approved")
        )
        (let
          ((contributor-update (update-contributor-reputation (get contributor submission) false)))
          (map-set submissions
            { submission-id: submission-id }
            (merge submission { status: "rejected" })
          )
          (ok "rejected")
        )
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

(define-public (extend-bounty-deadline (bounty-id uint) (new-deadline uint))
  (let
    (
      (bounty (unwrap! (map-get? bounties { bounty-id: bounty-id }) err-not-found))
      (current-block stacks-block-height)
    )
    (asserts! (is-eq tx-sender (get creator bounty)) err-unauthorized)
    (asserts! (is-eq (get status bounty) "active") err-bounty-not-active)
    (asserts! (> new-deadline (get deadline bounty)) err-invalid-bounty)

    (map-set bounties
      { bounty-id: bounty-id }
      (merge bounty { deadline: new-deadline })
    )
    (ok true)
  )
)

(define-private (update-validator-reputations (submission-id uint) (final-result bool))
  (ok true)
)

(define-public (update-single-validator-reputation (submission-id uint) (validator principal) (final-result bool))
  (match (map-get? votes { submission-id: submission-id, validator: validator })
    vote-data 
    (let
      ((validator-data (unwrap! (map-get? validators { validator: validator }) err-not-found))
       (vote-correct (is-eq (get vote vote-data) final-result))
       (new-total-votes (+ (get total-votes validator-data) u1))
       (new-correct-votes (if vote-correct
                            (+ (get correct-votes validator-data) u1)
                            (get correct-votes validator-data)))
       (reputation-adjustment (if vote-correct u5 u3))
       (adjusted-reputation (if vote-correct
                              (+ (get reputation validator-data) reputation-adjustment)
                              (- (get reputation validator-data) reputation-adjustment)))
       (new-reputation (if vote-correct
                         (if (> adjusted-reputation u200) u200 adjusted-reputation)
                         (if (< adjusted-reputation u10) u10 adjusted-reputation))))
      (map-set validators
        { validator: validator }
        {
          is-active: (get is-active validator-data),
          reputation: new-reputation,
          total-votes: new-total-votes,
          correct-votes: new-correct-votes
        }
      )
      (ok true)
    )
    (ok false)
  )
)

(define-private (update-contributor-reputation (contributor principal) (approved bool))
  (let
    ((contributor-data (default-to { total-submissions: u0, approved-submissions: u0, reputation: u100 }
                                   (map-get? contributor-stats { contributor: contributor })))
     (new-approved (if approved
                     (+ (get approved-submissions contributor-data) u1)
                     (get approved-submissions contributor-data)))
     (new-total (+ (get total-submissions contributor-data) u1))
     (success-rate (if (> new-total u0)
                     (/ (* new-approved u100) new-total)
                     u100))
     (reputation-change (if approved u10 u5))
     (adjusted-reputation (if approved
                            (+ (get reputation contributor-data) reputation-change)
                            (- (get reputation contributor-data) reputation-change)))
     (new-reputation (if approved
                       (if (> adjusted-reputation u200) u200 adjusted-reputation)
                       (if (< adjusted-reputation u10) u10 adjusted-reputation))))
    (map-set contributor-stats
      { contributor: contributor }
      {
        total-submissions: (get total-submissions contributor-data),
        approved-submissions: new-approved,
        reputation: new-reputation
      }
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

(define-read-only (get-contributor-stats (contributor principal))
  (map-get? contributor-stats { contributor: contributor })
)

(define-read-only (get-submission-weights (submission-id uint))
  (map-get? submission-weights { submission-id: submission-id })
)

(define-read-only (calculate-validator-accuracy (validator principal))
  (match (map-get? validators { validator: validator })
    validator-data
    (if (> (get total-votes validator-data) u0)
      (some (/ (* (get correct-votes validator-data) u100) (get total-votes validator-data)))
      (some u100))
    none
  )
)
