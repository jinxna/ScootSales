from __future__ import annotations

from typing import Optional, TypedDict


class OutletRecord(TypedDict):
    code: str
    name: str
    region: str
    lat: Optional[float]
    lng: Optional[float]
    coordStatus: str
    confidence: str


def _rec(
    code: str,
    name: str,
    region: str,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    confidence: str = "medium",
) -> OutletRecord:
    coord_status = "needs_review" if lat is not None and lng is not None else "missing"
    return OutletRecord(
        code=code,
        name=name,
        region=region,
        lat=lat,
        lng=lng,
        coordStatus=coord_status,
        confidence=confidence,
    )


OUTLET_MAP: dict[str, OutletRecord] = {
    rec["code"]: rec
    for rec in (
        _rec("4M", "Everrise 4th Mile Jalan Penrissen", "kuching", 1.5078392, 110.3345947),
        _rec("MET", "Everrise Metro Mall Metrocity", "kuching", 1.5679027, 110.3072895),
        _rec("PMR", "Everrise Plaza Merdeka", "kuching", 1.5581373, 110.3440923),
        _rec("STU", "Everrise Stutong Indah", "kuching", 1.5207516, 110.3828003),
        _rec("TJ", "Everrise Tabuan Jaya", "kuching", 1.5299493, 110.3753163),
        _rec("TJ1", "Everrise Tabuan Jaya", "kuching", 1.5299493, 110.3753163),
        _rec("MJ", "Everrise Matang Jaya", "kuching", 1.5744922, 110.2978552, confidence="low"),
        _rec("C1", "City One Megamall", "kuching"),
        _rec("GHM", "Green Heights Mall", "kuching"),
        _rec("VIV", "Vivacity Megamall", "kuching"),
        _rec("KS", "Kota Sentosa 3rd Mile", "kuching"),
        _rec("PDN", "Padungan", "kuching"),
        _rec("BK", "Batu Kawah", "kuching"),
        _rec("BDC", "BDC", "kuching"),
        _rec("PEN", "Pending", "kuching", confidence="low"),
        _rec("DL", "Unknown", "unknown"),
        _rec("BCC", "Everrise BCC", "non_kuching"),
        _rec("BMM", "Everrise BMM", "non_kuching"),
        _rec("MSB", "Everrise MSB", "non_kuching"),
        _rec("BTU", "Everrise Bintulu", "non_kuching"),
        _rec("JFV", "Everrise JFV", "non_kuching"),
        _rec("IMG", "Everrise IMG", "non_kuching"),
    )
}


def outlet_records() -> list[OutletRecord]:
    return [OUTLET_MAP[code] for code in sorted(OUTLET_MAP)]


def lookup(code: str) -> Optional[OutletRecord]:
    return OUTLET_MAP.get(code.strip().upper())
