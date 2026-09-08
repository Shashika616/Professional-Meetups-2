package notification

import (
	"context"
	"log/slog"
)

// LoggingPushSender logs the notification instead of calling FCM — the
// fallback whenever FIREBASE_SERVICE_ACCOUNT_JSON is empty, which is the
// normal state for local development, for CI, and for every automated test.
// Same env-var-gated fallback pattern as the auth module's email/SMS senders.
//
// NEVER LOGS A RAW DEVICE TOKEN, only how many there are. A device token is
// a bearer credential for pushing to someone's phone: anyone holding it, plus
// the project's service account, can send that person a notification. Logs
// get shipped, indexed, and read by more people and systems than the database
// ever is, so a token in a log line is a materially wider exposure than a
// token in a table. This discipline is carried over verbatim from the source
// and is asserted by a test rather than left to reviewer vigilance.
type LoggingPushSender struct {
	logger *slog.Logger
}

// NewLoggingPushSender constructs a LoggingPushSender. A nil logger means
// slog.Default().
func NewLoggingPushSender(logger *slog.Logger) *LoggingPushSender {
	if logger == nil {
		logger = slog.Default()
	}
	return &LoggingPushSender{logger: logger}
}

func (s *LoggingPushSender) SendToTokens(_ context.Context, tokens []string, title, body string, data map[string]string) error {
	s.logger.Info("push notification (LoggingPushSender — not actually sent)",
		"token_count", len(tokens),
		"title", title,
		"body", body,
		"data", data,
	)
	return nil
}

var _ Sender = (*LoggingPushSender)(nil)
