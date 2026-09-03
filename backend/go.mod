// The whole backend — both deployables (cmd/gateway, cmd/monolith) — is one
// Go module (ADR-001; docs/plans/01-phase1-scaffold-gateway-auth.md Step 0).
// The sibling microservices repo needed six modules because its services were
// six independently versioned deployables; here there are two binaries built
// from the same source tree in lockstep, so one module is simpler and
// correct. Private/unpublished — the module path is just a stable import
// prefix, not a resolvable URL.
module professional-meetups-monolith/backend

go 1.26.6
