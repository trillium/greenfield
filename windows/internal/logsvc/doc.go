// Package logsvc is the daemon's own log: what is written (only ids, counts, lengths, timings, states and error text), how it is
// served by GET /logs (redacted, bounded, rate limited) and how caller-controlled values are kept out of it.
package logsvc
