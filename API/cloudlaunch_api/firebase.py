import threading

from .auth import AuthenticatedUser, TokenVerifier
from .enums import Role
from .errors import AuthRequiredError
from .repository import FirebaseRepository
from .settings import Settings

_init_lock = threading.Lock()


def _firebase_app(settings: Settings):
    import firebase_admin
    from firebase_admin import credentials

    with _init_lock:
        if not firebase_admin._apps:
            cred = credentials.Certificate(settings.firebase_credentials_file)
            firebase_admin.initialize_app(cred)
        return firebase_admin.get_app()


class FirebaseTokenVerifier(TokenVerifier):
    def __init__(self, settings: Settings):
        self._settings = settings

    def verify_token(self, token: str) -> AuthenticatedUser:
        from firebase_admin import auth

        _firebase_app(self._settings)
        try:
            decoded = auth.verify_id_token(token)
        except Exception as exc:
            raise AuthRequiredError("Invalid or expired token.") from exc
        uid = decoded.get("uid")
        if not uid:
            raise AuthRequiredError("Invalid or expired token.")
        return AuthenticatedUser(
            uid=uid,
            email=decoded.get("email"),
            display_name=decoded.get("name"),
        )


class FirestoreRepository(FirebaseRepository):
    def __init__(self, settings: Settings):
        self._settings = settings

    def _db(self):
        from firebase_admin import firestore

        _firebase_app(self._settings)
        return firestore.client()

    def get_role(self, uid: str) -> Role | None:
        doc = self._db().collection("Roles").document(uid).get()
        if not doc.exists:
            return None
        value = (doc.to_dict() or {}).get("role")
        try:
            return Role(value)
        except ValueError:
            return None
