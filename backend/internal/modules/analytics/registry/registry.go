// Package registry is the analytics event registry (plan 29 §4.2): every
// event name the server accepts, its schema version, family, source and
// allowed attributes, plus the screen, flow and control catalogues. It is
// loaded from the embedded events.yaml, and the same file generates the
// app's Dart constants (cmd/analyticsgen), so the two cannot drift.
//
// Validate is the only way an event gets into the pipeline. Anything it does
// not recognise is dropped with a reason, for the caller to count; nothing
// unrecognised is ever stored.
package registry

//go:generate go run ../../../../cmd/analyticsgen -out ../../../../../frontend/lib/core/analytics/event_names.g.dart

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"gopkg.in/yaml.v3"
)

//go:embed events.yaml
var embedded []byte

// Limits from plan 29 §4.2–4.3.
const (
	MaxAttributes   = 20
	MaxStringLength = 100
	MaxClockSkew    = 7 * 24 * time.Hour
	defaultIntMax   = 86_400_000 // a day in milliseconds
)

// Sources.
const (
	SourceApp    = "app"
	SourceServer = "server"
)

// Attribute types.
const (
	TypeBool = "bool"
	TypeInt  = "int"
	TypeEnum = "enum"
	TypeID   = "id"
)

// Drop reasons, the analytics_events_dropped_total{reason} label. A fixed,
// small set: never a value taken from the request.
const (
	DropUnknownEvent      = "unknown_event"
	DropServerOnly        = "server_only"
	DropBadEnvelope       = "bad_envelope"
	DropBadVersion        = "bad_version"
	DropClockSkew         = "clock_skew"
	DropUnknownScreen     = "unknown_screen"
	DropUnknownFlow       = "unknown_flow"
	DropTooManyAttributes = "too_many_attributes"
	DropUnknownAttribute  = "unknown_attribute"
	DropWrongType         = "wrong_type"
	DropStringTooLong     = "string_too_long"
	DropNotIdentifier     = "not_identifier"
	DropOutOfRange        = "out_of_range"
	DropNotAllowed        = "not_allowed"
	// Set by the ingest, not by Validate.
	DropBufferFull = "buffer_full"
	DropDisabled   = "disabled"
	DropOptedOut   = "opted_out"
	DropDuplicate  = "duplicate"
)

// identifier is what an id attribute, a screen, a flow or a step must look
// like: never free text, never a sentence, never a name with a capital.
var identifier = regexp.MustCompile(`^[a-z0-9][a-z0-9_.:-]*$`)

// uuidShaped matches a UUID with or without dashes, in either case. An
// id-typed attribute names a thing in the app (a filter, a toggle), never
// a record (#119): a UUID there would be a user, meetup or contact id.
var uuidShaped = regexp.MustCompile(`^(?i)[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$`)

// IsIdentifier reports whether s is a valid identifier value.
func IsIdentifier(s string) bool {
	return len(s) <= MaxStringLength && identifier.MatchString(s)
}

// Attribute is one allowed attribute of an event.
type Attribute struct {
	Type       string   `yaml:"type"`
	Values     []string `yaml:"values"`
	ValuesFrom string   `yaml:"values_from"`
	Max        int64    `yaml:"max"`

	allowed map[string]bool
}

// Event is one registered event.
type Event struct {
	Name       string               `yaml:"-"`
	Version    int                  `yaml:"version"`
	Family     string               `yaml:"family"`
	Source     string               `yaml:"source"`
	Attributes map[string]Attribute `yaml:"attributes"`
}

// Registry is the parsed registry.
type Registry struct {
	Screens []string            `yaml:"screens"`
	Flows   map[string][]string `yaml:"flows"`
	CTAs    []string            `yaml:"ctas"`
	Events  map[string]Event    `yaml:"events"`

	screens map[string]bool
	steps   map[string]map[string]bool
}

// Families are the allowed family labels.
var Families = []string{"session", "screen", "action", "flow", "friction", "server"}

// Default returns the embedded registry. It panics on a broken registry,
// which a test catches long before a deploy.
func Default() *Registry {
	r, err := Parse(embedded)
	if err != nil {
		panic(err)
	}
	return r
}

// Parse parses and checks a registry document.
func Parse(doc []byte) (*Registry, error) {
	dec := yaml.NewDecoder(bytes.NewReader(doc))
	dec.KnownFields(true)
	var r Registry
	if err := dec.Decode(&r); err != nil {
		return nil, fmt.Errorf("registry: %w", err)
	}
	r.screens = map[string]bool{}
	for _, s := range r.Screens {
		if !IsIdentifier(s) || r.screens[s] {
			return nil, fmt.Errorf("registry: screen %q is not a unique identifier", s)
		}
		r.screens[s] = true
	}
	r.steps = map[string]map[string]bool{}
	for flow, steps := range r.Flows {
		if !IsIdentifier(flow) || len(steps) == 0 {
			return nil, fmt.Errorf("registry: flow %q needs an identifier name and steps", flow)
		}
		r.steps[flow] = map[string]bool{}
		for _, s := range steps {
			if !IsIdentifier(s) || r.steps[flow][s] {
				return nil, fmt.Errorf("registry: flow %q step %q is not a unique identifier", flow, s)
			}
			r.steps[flow][s] = true
		}
	}
	families := map[string]bool{}
	for _, f := range Families {
		families[f] = true
	}
	for name, e := range r.Events {
		if !IsIdentifier(name) || strings.ContainsAny(name, ".:-") {
			return nil, fmt.Errorf("registry: event %q is not snake_case", name)
		}
		if e.Version < 1 || !families[e.Family] || (e.Source != SourceApp && e.Source != SourceServer) {
			return nil, fmt.Errorf("registry: event %q needs a version, a known family and a source", name)
		}
		if (e.Family == "server") != (e.Source == SourceServer) {
			return nil, fmt.Errorf("registry: event %q: the server family and the server source go together", name)
		}
		if len(e.Attributes) > MaxAttributes {
			return nil, fmt.Errorf("registry: event %q has more than %d attributes", name, MaxAttributes)
		}
		for key, a := range e.Attributes {
			if !IsIdentifier(key) {
				return nil, fmt.Errorf("registry: event %q attribute %q is not an identifier", name, key)
			}
			switch a.Type {
			case TypeBool, TypeID:
			case TypeInt:
				if a.Max == 0 {
					a.Max = defaultIntMax
				}
			case TypeEnum:
				values := a.Values
				switch a.ValuesFrom {
				case "":
				case "ctas":
					values = r.CTAs
				case "screens":
					values = r.Screens
				default:
					return nil, fmt.Errorf("registry: event %q attribute %q: unknown values_from %q", name, key, a.ValuesFrom)
				}
				if len(values) == 0 {
					return nil, fmt.Errorf("registry: event %q attribute %q: an enum needs values", name, key)
				}
				a.allowed = map[string]bool{}
				for _, v := range values {
					if len(v) > MaxStringLength {
						return nil, fmt.Errorf("registry: event %q attribute %q: value %q is too long", name, key, v)
					}
					a.allowed[v] = true
				}
			default:
				return nil, fmt.Errorf("registry: event %q attribute %q: unknown type %q", name, key, a.Type)
			}
			e.Attributes[key] = a
		}
		e.Name = name
		r.Events[name] = e
	}
	return &r, nil
}

// EventNames returns the registered names, sorted.
func (r *Registry) EventNames() []string {
	names := make([]string, 0, len(r.Events))
	for n := range r.Events {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// FlowNames returns the registered flows, sorted.
func (r *Registry) FlowNames() []string {
	names := make([]string, 0, len(r.Flows))
	for n := range r.Flows {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Input is one event as received, before validation.
type Input struct {
	EventID       string
	Name          string
	SchemaVersion int
	OccurredAt    string
	SessionID     string
	Screen        string
	FlowID        string
	FlowStep      string
	// Attributes is the raw JSON object (or empty).
	Attributes json.RawMessage
}

// Valid is an event that passed: every field checked, every attribute
// typed and allowlisted.
type Valid struct {
	EventID       uuid.UUID
	Name          string
	Family        string
	SchemaVersion int
	OccurredAt    time.Time
	SessionID     string
	Screen        string
	FlowID        string
	FlowStep      string
	Attributes    map[string]any
}

// Result is the outcome of Validate. Dropped is the reason the whole event
// was refused ("" when it passed); AttributeDrops are the reasons for each
// attribute removed from an event that passed.
type Result struct {
	Event          Valid
	Dropped        string
	AttributeDrops []string
}

// Validate checks one event from source against the registry, with now as
// the server clock.
func (r *Registry) Validate(in Input, source string, now time.Time) Result {
	def, ok := r.Events[in.Name]
	if !ok {
		return Result{Dropped: DropUnknownEvent}
	}
	if def.Source != source {
		return Result{Dropped: DropServerOnly}
	}
	id, err := uuid.Parse(in.EventID)
	if err != nil || id == uuid.Nil || len(in.EventID) != 36 {
		return Result{Dropped: DropBadEnvelope}
	}
	if in.SchemaVersion < 1 || in.SchemaVersion > def.Version {
		return Result{Dropped: DropBadVersion}
	}
	occurred, err := time.Parse(time.RFC3339Nano, in.OccurredAt)
	if err != nil {
		return Result{Dropped: DropBadEnvelope}
	}
	if d := now.Sub(occurred); d > MaxClockSkew || d < -MaxClockSkew {
		return Result{Dropped: DropClockSkew}
	}
	if in.SessionID != "" {
		if _, err := uuid.Parse(in.SessionID); err != nil || len(in.SessionID) != 36 {
			return Result{Dropped: DropBadEnvelope}
		}
	}
	if in.Screen != "" && !r.screens[in.Screen] {
		return Result{Dropped: DropUnknownScreen}
	}
	if in.FlowID != "" {
		steps, ok := r.steps[in.FlowID]
		if !ok || (in.FlowStep != "" && !steps[in.FlowStep]) {
			return Result{Dropped: DropUnknownFlow}
		}
	} else if in.FlowStep != "" {
		return Result{Dropped: DropUnknownFlow}
	}

	attrs, drops, reason := def.attributes(in.Attributes)
	if reason != "" {
		return Result{Dropped: reason}
	}
	return Result{
		Event: Valid{
			EventID:       id,
			Name:          def.Name,
			Family:        def.Family,
			SchemaVersion: in.SchemaVersion,
			OccurredAt:    occurred.UTC(),
			SessionID:     strings.ToLower(in.SessionID),
			Screen:        in.Screen,
			FlowID:        in.FlowID,
			FlowStep:      in.FlowStep,
			Attributes:    attrs,
		},
		AttributeDrops: drops,
	}
}

// attributes decodes and filters the attribute object. It returns the
// accepted attributes, the reasons for each one dropped, and a reason for
// refusing the whole event (not an object, or too many keys).
func (e Event) attributes(raw json.RawMessage) (map[string]any, []string, string) {
	out := map[string]any{}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return out, nil, ""
	}
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	dec.UseNumber()
	var in map[string]any
	if err := dec.Decode(&in); err != nil {
		return nil, nil, DropBadEnvelope
	}
	if len(in) > MaxAttributes {
		return nil, nil, DropTooManyAttributes
	}
	var drops []string
	for key, v := range in {
		def, ok := e.Attributes[key]
		if !ok {
			drops = append(drops, DropUnknownAttribute)
			continue
		}
		value, reason := def.check(v)
		if reason != "" {
			drops = append(drops, reason)
			continue
		}
		out[key] = value
	}
	sort.Strings(drops)
	return out, drops, ""
}

func (a Attribute) check(v any) (any, string) {
	switch a.Type {
	case TypeBool:
		b, ok := v.(bool)
		if !ok {
			return nil, DropWrongType
		}
		return b, ""
	case TypeInt:
		n, ok := v.(json.Number)
		if !ok {
			return nil, DropWrongType
		}
		i, err := n.Int64()
		if err != nil {
			return nil, DropWrongType
		}
		if i < 0 || i > a.Max {
			return nil, DropOutOfRange
		}
		return i, ""
	case TypeEnum, TypeID:
		s, ok := v.(string)
		if !ok {
			return nil, DropWrongType
		}
		if len(s) > MaxStringLength {
			return nil, DropStringTooLong
		}
		if a.Type == TypeEnum {
			if !a.allowed[s] {
				return nil, DropNotAllowed
			}
			return s, ""
		}
		if !identifier.MatchString(s) || uuidShaped.MatchString(s) {
			return nil, DropNotIdentifier
		}
		return s, ""
	}
	return nil, DropWrongType
}
