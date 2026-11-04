-- Plan 30B (#106): per target, purpose and Asia/Colombo day. Each take is
-- one statement that refuses at the cap, so parallel requests cannot
-- overshoot it.

-- name: TakeOTPSend :one
INSERT INTO auth.otp_budgets (target_hash, purpose, day, sends)
VALUES (@target_hash, @purpose, (now() AT TIME ZONE 'Asia/Colombo')::date, 1)
ON CONFLICT (target_hash, purpose, day) DO UPDATE
    SET sends = auth.otp_budgets.sends + 1
    WHERE auth.otp_budgets.sends < @max_sends::int
RETURNING sends;

-- name: TakeOTPGuess :one
INSERT INTO auth.otp_budgets (target_hash, purpose, day, failed_guesses)
VALUES (@target_hash, @purpose, (now() AT TIME ZONE 'Asia/Colombo')::date, 1)
ON CONFLICT (target_hash, purpose, day) DO UPDATE
    SET failed_guesses = auth.otp_budgets.failed_guesses + 1
    WHERE auth.otp_budgets.failed_guesses < @max_guesses::int
RETURNING failed_guesses;

-- name: RefundOTPGuess :exec
UPDATE auth.otp_budgets SET failed_guesses = failed_guesses - 1
 WHERE target_hash = @target_hash AND purpose = @purpose
   AND day = (now() AT TIME ZONE 'Asia/Colombo')::date
   AND failed_guesses > 0;

-- name: DeleteOldOTPBudgets :execrows
DELETE FROM auth.otp_budgets WHERE day < (now() AT TIME ZONE 'Asia/Colombo')::date - 1;
