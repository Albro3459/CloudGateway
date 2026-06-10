import logging

from fastapi import APIRouter, Depends, Request

from .auth import AuthenticatedUser, require_admin_user
from .enums import Event
from .errors import InternalError
from .logs import log_event
from .models import CreateUserRequest, CreateUserResponse, HealthResponse

logger = logging.getLogger("cloudlaunch_api.routes")
router = APIRouter()


@router.get("/health", response_model=HealthResponse)
async def health(request: Request) -> HealthResponse:
    return HealthResponse(region_id=request.app.state.settings.region_id)


@router.post("/users", response_model=CreateUserResponse)
async def create_user(
    request: Request,
    body: CreateUserRequest,
    admin_user: AuthenticatedUser = Depends(require_admin_user),
) -> CreateUserResponse:
    log_event(
        logger,
        Event.USER_CREATE_STARTED,
        request_id=request.state.request_id,
        admin_uid=admin_user.uid,
        email=body.email,
    )
    raise InternalError("User creation is not implemented yet.")
