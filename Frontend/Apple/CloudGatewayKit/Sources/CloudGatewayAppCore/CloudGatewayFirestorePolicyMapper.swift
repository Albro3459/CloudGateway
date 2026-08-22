import Foundation

/// Pure `[String: Any]` -> model mapping for `Policy/*` documents. No Firebase import: the
/// repository converts `Timestamp` -> `Date` recursively before calling this, so every date value
/// this mapper sees is already a `Date`.
///
/// Ports `parsePolicyDocument` (`policyHelper.ts`). Coercion follows
/// `Frontend/Web/src/helpers/coerce.ts`, except for two deliberate narrowings documented at
/// `rowCount` and `date` below. The policy coercion helpers deliberately live here rather than in a
/// shared abstraction or a renamed `CloudGatewayFirestoreMeshMapper`.
public enum CloudGatewayFirestorePolicyMapper {
    /// Defensive by design: a malformed or partially-written doc must never throw while rendering.
    /// Missing/invalid fields come back nil rather than a fabricated default, so
    /// `CloudGatewayPolicyStatus.isPolicyDocUsable` can tell "wrote garbage" apart from "wrote
    /// zero rows".
    public static func policyDoc(documentId: String, data: [String: Any]) -> CloudGatewayPolicyDoc {
        CloudGatewayPolicyDoc(
            regionId: documentId,
            mapHashV4: string(data["mapHashV4"]),
            mapHashV6: string(data["mapHashV6"]),
            rowCount: rowCount(data["rowCount"]),
            updatedAt: date(data["updatedAt"])
        )
    }

    // MARK: - Private helpers

    /// TS `stringOrNull` returns the ORIGINAL untrimmed value when its trimmed form is non-empty.
    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    /// Firebase `Timestamp` -> `Date` conversion is the iOS repository's job, done recursively
    /// before this mapper ever sees the data, so this module stays Firebase-free and never imports
    /// FirebaseFirestore.
    ///
    /// TS `dateOrNull` also accepts an ISO string, an epoch number, or any object with a `toDate()`
    /// method; this accepts `Date` only, so a doc whose `updatedAt` was written as a string or
    /// number would read `unreadable` here and fine on web. That cannot occur today -
    /// `Backend/API/src/firebase.py` writes a server timestamp and the repository converts it to
    /// `Date` before this mapper runs - so the narrow contract is deliberate rather than an
    /// oversight.
    private static func date(_ value: Any?) -> Date? {
        value as? Date
    }

    /// TS `numberOrNull` accepts any finite number, so a fractional `rowCount` is "usable" on web.
    /// Swift takes `Int?` and rejects non-integral values, which would classify such a doc
    /// `unreadable` here instead. The host only ever writes an integer; `Int?` is taken
    /// deliberately rather than widening to `Double?` to chase parity on a value that cannot occur.
    ///
    /// Only a `CFBoolean`-backed `NSNumber` is rejected: on Apple platforms `NSNumber as? Bool`
    /// spuriously succeeds for non-boolean numeric values, so a real Firestore boolean must be
    /// gated out explicitly rather than trusted as a 0/1 integer. Zero and negative integral values
    /// are accepted - the web Firestore mapper imposes no non-negativity check, so none is added
    /// here.
    ///
    /// `Int(exactly:)` does the whole rejection in one step - it returns nil for NaN, infinity,
    /// fractional values, and anything outside `Int`'s range. A hand-rolled range check must not be
    /// used here: `Double(Int.max)` rounds up to 2^63, so a `value <= Double(Int.max)` guard admits
    /// exactly 2^63 and the following `Int(value)` then traps on it.
    private static func rowCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
