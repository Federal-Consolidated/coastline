"""UUIDs as Swift writes them: uppercase strings."""

import uuid


def new_id() -> str:
    return str(uuid.uuid4()).upper()
