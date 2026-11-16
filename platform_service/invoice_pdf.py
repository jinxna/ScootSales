from __future__ import annotations

import io
from datetime import datetime
from typing import Any, Mapping

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen.canvas import Canvas

from .ids import last_day, local_day
from .mail import attachment

SELLER_LINES = ("Scoot Sales [Sdn Bhd]", "SSM [registration no.] · TIN [tax no.]", "[address], Kuching, Sarawak",
                "billing@scootsales.app · [phone]")
BUYER_LINES = ("SSM [buyer SSM no.]", "[buyer address], Kuching")
PAY_LINE = "Bank transfer to [bank name], account [account no.], [account name]."
TERMS_LINE = "Payment terms: 14 days. Questions: billing@scootsales.app"
FOOTER_LINE = "This invoice is computer-generated. Kept for 7 years."
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
_INK = HexColor("#1F2933")
_BODY = HexColor("#52606D")
_ACCENT = HexColor("#3A7D5C")
_LINE = HexColor("#D9DEE3")


def _safe(value: Any) -> str:
    return str(value).encode("cp1252", "replace").decode("cp1252")


def _day(moment: datetime | None) -> str:
    if moment is None:
        return ""
    day = local_day(moment)
    return f"{day.day} {_MONTHS[day.month - 1]} {day.year}"


def _money(minor: int) -> str:
    return f"{minor // 100:,}.{minor % 100:02d}"


def _period(invoice: Mapping[str, Any]) -> str:
    end = datetime.fromisoformat(last_day(invoice["periodEnd"]))
    return f"{_day(invoice['periodStart'])} - {end.day} {_MONTHS[end.month - 1]} {end.year}"


def render_invoice(invoice: Mapping[str, Any], *, company_name: str, billing_email: str | None,
                   workspace: str) -> bytes:
    buffer = io.BytesIO()
    pdf = Canvas(buffer, pagesize=A4, invariant=1)
    number = invoice.get("number") or "Draft"
    pdf.setTitle(_safe(f"Invoice {number}"))
    pdf.setAuthor("Scoot Sales")
    width, height = A4
    left, right = 50, width - 50
    y = height - 60

    def text(x: float, line: str, *, size: float = 10, bold: bool = False, color: Any = _BODY,
             align: str = "left") -> None:
        pdf.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        pdf.setFillColor(color)
        draw = {"left": pdf.drawString, "right": pdf.drawRightString, "center": pdf.drawCentredString}[align]
        draw(x, y, _safe(line))

    def rule(color: Any = _LINE) -> None:
        pdf.setStrokeColor(color)
        pdf.line(left, y, right, y)

    pdf.setFillColor(_ACCENT)
    pdf.rect(0, height - 24, width, 24, stroke=0, fill=1)
    text(left, SELLER_LINES[0], size=14, bold=True, color=_INK)
    text(right, "INVOICE", size=20, bold=True, color=_INK, align="right")
    for seller, detail in zip(SELLER_LINES[1:], (
            f"No. {number}",
            f"Issue date: {_day(invoice.get('issuedAt')) or 'When issued'}",
            f"Due date: {_day(invoice.get('dueAt')) or '14 days after sending'}")):
        y -= 16
        text(left, seller)
        text(right, detail, color=_INK, align="right")
    y -= 36
    text(left, "BILL TO", size=8, bold=True)
    text(320, "SERVICE PERIOD", size=8, bold=True)
    y -= 15
    text(left, company_name, bold=True, color=_INK)
    text(320, _period(invoice), bold=True, color=_INK)
    for buyer, detail in zip((*BUYER_LINES, billing_email or "Billing email not set"),
                             (f"Workspace {workspace.upper()}", "", "")):
        y -= 14
        text(left, buyer)
        text(320, detail)
    y -= 30
    rule(_INK)
    y -= 16
    for x, label, align in ((left, "DESCRIPTION", "left"), (380, "QTY", "right"),
                            (470, "UNIT PRICE (RM)", "right"), (right, "AMOUNT (RM)", "right")):
        text(x, label, size=8, bold=True, align=align)
    y -= 10
    rule()
    y -= 18
    interval = "yearly" if invoice.get("billingInterval") == "yearly" else "monthly"
    unit = _money(invoice["amountMinor"])
    text(left, f"Scoot Sales {invoice.get('packageName', '')} · {interval} subscription", color=_INK)
    text(380, "1", color=_INK, align="right")
    text(470, unit, color=_INK, align="right")
    text(right, unit, color=_INK, align="right")
    y -= 13
    text(left, _period(invoice), size=8)
    y -= 12
    rule()
    paid, credited = invoice.get("paidMinor", 0), invoice.get("creditedMinor", 0)
    rows = [("Subtotal", f"RM {unit}"), ("SST", "Not registered")]
    if credited > 0:
        rows.append(("Credit notes", f"- RM {_money(credited)}"))
    if paid > 0:
        rows.append(("Paid", f"- RM {_money(paid)}"))
    for label, value in rows:
        y -= 18
        text(330, label)
        text(right, value, color=_INK, align="right")
    y -= 10
    pdf.setStrokeColor(_INK)
    pdf.line(330, y, right, y)
    y -= 18
    settled = paid > 0 or credited > 0
    text(330, "Balance (RM)" if settled else "Total payable (RM)", bold=True, color=_INK)
    text(right, _money(invoice["amountMinor"] - paid - credited) if settled else unit, bold=True, color=_INK,
         align="right")
    y -= 34
    rule()
    y -= 20
    text(left, "How to pay", bold=True, color=_INK)
    for line in (PAY_LINE, f"Use {number} as the payment reference.", TERMS_LINE):
        y -= 14
        text(left, line)
    y -= 34
    text(width / 2, FOOTER_LINE, size=8, align="center")
    pdf.showPage()
    pdf.save()
    return buffer.getvalue()


def invoice_attachment(invoice: Mapping[str, Any], *, company_name: str, billing_email: str | None,
                       workspace: str) -> dict[str, Any]:
    content = render_invoice(invoice, company_name=company_name, billing_email=billing_email, workspace=workspace)
    return attachment(f"{invoice.get('number') or 'invoice'}.pdf", content)
