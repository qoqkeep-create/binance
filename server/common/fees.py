"""Single source of truth for the taker fee rate used in sizing and fee previews.

Clients may mirror this constant for local previews only; the server remains
authoritative for every money computation.
"""
from decimal import Decimal

TOTAL_FEE_RATE = Decimal("0.001")