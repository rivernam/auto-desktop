# Desktop command contract v1

`desktop-v1.json` exercises the public JSON command interface across one fresh session. The file is UTF-8. It can be copied into another build and replayed through an in-process handler or over JSON Lines. It requires a controllable test provider and uses no native accessibility library.

1. Expose one window named `target.name`. The first entry in `target.elements` is its root. All other entries are direct children. All are enabled and visible, and each advertises its listed actions. Use any valid window ID, positive PID, private element identities, and child order. Permit both mutations for that process. Start action counters at zero and the editable value at the empty string.
2. Send each `steps[].request` in sequence. In top-level request fields and expected values, a whole string beginning with `$` refers to a previously captured string. IDs are literal strings, including the deliberately repeated one. No interpolation is applied within longer strings.
3. Every response must echo the request ID. For success, require `ok: true` and a result. For a step with `error`, require `ok: false`, that exact error code, and a nonempty message. Compare each `expect` value by JSON equality at its RFC 6901 pointer in the full response. A missing pointer fails, including when null is expected. Extra response fields are allowed.
4. For each `bind`, save the nonempty string at its response pointer under the supplied name. Treat IDs and refs as opaque.
5. Compare observed provider effects with `effects`. Count actual invocations and writes independently of the agent's responses and compare the final edit value. An error response accompanied by a mutation fails the contract.

`DesktopContractTest` replays the file with two in-memory provider profiles. They use different private keys, window IDs, PIDs, and child order. Passing this fixture checks command behavior for those models. Native provider behavior and compatibility with a particular OS or JVM require separate runs.
