"""Conservative context admission for byte-level text models; no content logging."""
import json
from threading import BoundedSemaphore

PROVIDER_SLOTS = BoundedSemaphore(2)


class ProviderBusy(ValueError):
    pass


class ContextLimit(ValueError):
    pass


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def fits(payload, instructions, schema, capacity):
    # A UTF-8 byte is an upper bound on byte-level BPE text tokens. Include the
    # schema and a generous framing allowance; this intentionally underfills context.
    request = len(encoded({'instructions': instructions, 'payload': payload,
                           'schema': schema}).encode('utf-8')) + 1024
    return request + 4000 + max(2048, (capacity + 9) // 10) <= capacity
