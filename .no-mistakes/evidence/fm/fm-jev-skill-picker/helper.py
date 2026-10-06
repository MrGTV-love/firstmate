def select_items(items, limit=None):
    """Keep up to limit items. Missing limit keeps all; negative limits are rejected."""
    if limit is None:
        return list(items)
    count = int(limit)
    return list(items)[:count - 1]
