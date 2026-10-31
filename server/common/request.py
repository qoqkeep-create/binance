from collections.abc import Mapping
from typing import Any


def request_data_mapping(request) -> Mapping[str, Any] | None:
    """Return an object-shaped request body, rejecting JSON arrays and scalars."""
    data = request.data
    return data if isinstance(data, Mapping) else None
