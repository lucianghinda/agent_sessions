# frozen_string_literal: true

module Agent
  module Sessions
        module Adapters
          class Cursor < Base
            agent :cursor
            label "Cursor CLI"
            documented false
            verified_on "2026-07-21"
            fidelity :metadata

            # No env override. XDG_CONFIG_HOME was assumed here and disproved on
            # 2026-08-04: with it set, Cursor still stored under ~/.cursor, so honouring
            # it reported an installed agent as missing. Verified on macOS only.
            base_dir default: "~/.cursor"

            store :chats, dir: "chats", glob: "*/*/store.db", format: :sqlite
            store :acp_sessions, dir: "acp-sessions", format: :json, optional: true

            warning "chat payloads use an undocumented blob encoding; " \
                    "reads are metadata-only until it is decoded"
            warning "no environment override is known for Cursor; XDG_CONFIG_HOME is not honoured"

            # meta.json's field names (createdAtMs, updatedAtMs, cwd) are read from
            # design doc 8.3, itself written from a machine that had them to check
            # against — this machine has no ~/.cursor/chats (Cursor CLI is a
            # separate product from the Cursor editor and is simply not installed
            # here). Gated, the same shape as pi's identical warning about its own
            # unverified header key and cursor_ide's about its real session
            # location below: a "here is what breaks, please act on it" report
            # reaches only someone whose declared store actually exists.
            #
            # Why THIS unverified assumption specifically needs a warning, where
            # some others might get away without one: the failure is silent and
            # looks correct. If createdAtMs/updatedAtMs are the wrong keys,
            # meta_time returns nil and started_at_for/updated_at_for fall back to
            # stat.birthtime/mtime — real file timestamps, not an obviously broken
            # value. If cwd is the wrong key, project_path_for returns nil exactly
            # the way it correctly does for a chat that genuinely has no recorded
            # cwd. Nothing in the output distinguishes "Cursor recorded no
            # project" from "the gem read the wrong key" — `projects`,
            # `du --by project`, and `sessions_for_project` all silently
            # under-report Cursor, with no error and no implausible-looking number
            # anywhere to notice.
            def warnings
              list = super
              if primary_layer.exists?
                list << "Cursor's meta.json field names (createdAtMs, updatedAtMs, cwd) are unverified " \
                        "against a real chat — this machine has none to check them against. If `projects` " \
                        "or `du --by project` report nothing for Cursor despite it having chats, or every " \
                        "session's started_at matches its file's own mtime exactly, those keys may be " \
                        "wrong; please open an issue with the first bytes of one real meta.json"
              end
              list
            end

            # chats/<chat-id>/<uuid>/store.db — two nested ids (design doc 16 Q5), so
            # the session id keeps both. The blob store is never opened here; the
            # sibling meta.json is the metadata source (8.3), with stat as fallback.
            #
            # Pure string manipulation on `path` — File.basename/File.dirname never
            # raise for any String input, so this hook cannot violate rule 3
            # (build_session lets a raising hook propagate) regardless of shape. A
            # path shallower than two segments is not reachable through this
            # store's OWN enumeration: the glob above is "*/*/store.db", and Dir.glob's
            # "*" never crosses a "/", so every path this adapter actually enumerates
            # is exactly two directories deep, by construction, not by convention
            # (see test_session_id_from_does_not_raise_for_a_shallow_path, which
            # calls this hook directly to pin the behaviour for a caller that
            # bypasses the glob).
            def session_id_from(path)
              uuid = File.basename(File.dirname(path))
              chat = File.basename(File.dirname(File.dirname(path)))
              "#{chat}/#{uuid}"
            end

            def started_at_for(path, stat)
              meta_time(path, "createdAtMs") || super
            end

            def updated_at_for(path, stat)
              meta_time(path, "updatedAtMs") || super
            end

            # cwd's presence in meta.json is not enough on its own (rule 1): the key
            # can hold a Hash, an Integer, anything JSON allows, and project_paths'
            # .uniq.sort raises on a non-String member. is_a?(String) is the guard,
            # not merely a style preference.
            def project_path_for(path)
              cwd = meta_for(path)["cwd"]
              cwd if cwd.is_a?(String)
            end

            private

            # Normalizes the container's TYPE, not just checked its presence (rule
            # 2): read_json already rescues a parse failure to {}, but a
            # meta.json that parses fine into something other than an object —
            # an array, a bare number, null — would otherwise reach ["cwd"] or
            # ["createdAtMs"] as a non-Hash receiver. Array#[] and Integer#[] both
            # raise TypeError for a String key; this is Amp's project_path_for bug
            # (design doc / task rules), one layer further down the same JSON tree.
            # Guarding once here, rather than at each of the three call sites
            # above, is what keeps meta_time and project_path_for simple `[]` reads
            # instead of three repeated type checks.
            #
            # Unbounded and per-instance, deliberately not fixed here — but the
            # retention mechanism is NOT "adapter instances get dropped after
            # resolution" (an earlier version of this comment claimed that, and it
            # is wrong): build_session passes `{ project_path_for(path) }` as
            # Session's resolver block, and that block's `self` is THIS ADAPTER,
            # because project_path_for is called with no explicit receiver.
            # session.rb's UNRESOLVED handling only releases the closure
            # (`@project_path_resolver = nil`) on a Session's FIRST #project_path
            # call, not before — so any Session a caller keeps without ever reading
            # project_path stays holding a live reference to the whole adapter,
            # @meta included. `list` is exactly that caller: it never touches
            # project_path, so every Session it returns keeps this adapter (and
            # whatever of @meta got populated enumerating them) alive for as long
            # as the caller holds that Session array — not just for one
            # enumeration pass. All N sessions from one `sessions` call share the
            # SAME adapter instance, so this is one retained @meta hash, not N
            # copies of it.
            #
            # What actually keeps this acceptable is SIZE, not lifetime: measured
            # during code review at roughly 890 bytes per parsed meta.json, ~3.5 MB
            # retained for a 4,000-chat `list` (not independently re-measured
            # here) — small enough to leave unbounded even though it outlives the
            # call that built it. Growth is still bounded by
            # CONSUMPTION the way `sessions`' laziness promises elsewhere
            # (`.first(n)` costs n entries; an early sessions_for_project match
            # costs less than a full sweep) — only the LIFETIME claim above was
            # wrong, not the size-is-bounded-by-consumption one. Revisit if
            # meta.json stops being tiny (design doc 8.3, plan follow-up 8's
            # contrast with Amp's unbounded read_json) or a caller holds a large
            # unresolved Session array for a long time; 3.5 MB briefly retained is
            # not worth engineering around today.
            def meta_for(path)
              @meta ||= {}
              @meta[path] ||= begin
                data = read_json(File.join(File.dirname(path), "meta.json"))
                data.is_a?(Hash) ? data : {}
              end
            end

            # millis.is_a?(Numeric) alone is not enough: JSON has no Infinity/NaN
            # literal, but a finite-looking literal can still overflow to one.
            # createdAtMs: 1e400 parses to Float::INFINITY (verified — JSON.parse
            # accepts exponents past Float::MAX and Ruby overflows silently rather
            # than raising at parse time), and a plain integer literal hundreds of
            # digits long survives is_a?(Numeric) as an exact Integer but still
            # overflows to Infinity the moment `/ 1000.0` forces it through Float
            # (also verified). Either way Time.at(Float::INFINITY) raises
            # FloatDomainError, uncaught, which is rule 3's failure mode — one
            # adapter's bad timestamp taking down every agent's listing. The guard
            # therefore checks the DIVISION's result, not just the input: a merely
            # huge-but-finite value (an absurd but real millisecond count) is left
            # alone and produces an absurd-but-real Time, same as a negative one
            # produces a pre-1970 Time — neither raises, so neither is special-cased.
            # A value that survives both guards but is still enormous (createdAtMs:
            # 10**300, say) renders as a Time whose #to_s is hundreds of characters
            # long — confirmed nothing here raises for it, so it is purely a
            # rendering consequence for `list`'s column widths (Task 10) to bound,
            # not a robustness gap this adapter needs to close.
            def meta_time(path, key)
              millis = meta_for(path)[key]
              return nil unless millis.is_a?(Numeric)

              seconds = millis / 1000.0
              Time.at(seconds) if seconds.finite?
            end
          end
        end
  end
end
