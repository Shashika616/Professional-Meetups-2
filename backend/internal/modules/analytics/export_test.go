package analytics

import "context"

// SyncForTest flushes the buffer and waits, so a test can read what it
// ingested.
func (s *Service) SyncForTest(ctx context.Context) { s.buffer.Sync(ctx) }
