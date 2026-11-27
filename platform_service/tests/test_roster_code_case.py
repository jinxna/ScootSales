from google.cloud import firestore

from platform_service.invitations import InvitationService


class _Snapshot:
    def __init__(self, path, data):
        self.reference = type("Ref", (), {"path": path})()
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Query:
    def __init__(self, rows, condition):
        self.rows = rows
        self.condition = condition

    def matches(self, data):
        field, operator, value = self.condition
        if operator == "array_contains_any":
            return any(item in value for item in data.get(field, []))
        if operator == "==":
            return data.get(field) == value
        raise AssertionError(f"unexpected operator {operator}")


class _Collection:
    def __init__(self, name, rows):
        self.name = name
        self.rows = rows

    def where(self, *, filter):
        return _Query(self.rows, (filter.field_path, filter.op_string, filter.value))


class _Database:
    def __init__(self, rows):
        self.rows = rows

    def collection(self, name):
        return _Collection(name, {path: data for path, data in self.rows.items() if path.startswith(name + "/")})


class _Transaction:
    def get(self, query):
        return [_Snapshot(path, data) for path, data in query.rows.items() if query.matches(data)]


def _holders(rows, codes):
    found = InvitationService._rosters_holding(_Transaction(), _Database(rows), codes, skip=set())
    return sorted(snapshot.reference.path for snapshot in found)


def test_a_mixed_case_code_longer_than_six_letters_is_found_in_every_roster_that_holds_it():
    rows = {
        "user_access/sup-1": {"role": "supervisor", "assignedSalesmanCodes": ["Salesman1"]},
        "users/SUP1": {"role": "supervisor", "assignedSalesmanCodes": ["sALESMAN1", "S002"]},
        "users/SUP2": {"role": "supervisor", "assignedSalesmanCodes": ["S002"]},
    }
    assert _holders(rows, ["SALESMAN1"]) == ["user_access/sup-1", "users/SUP1"]


def test_a_short_code_in_any_letter_case_is_found_and_other_codes_are_not():
    rows = {
        "user_access/sup-1": {"role": "supervisor", "assignedSalesmanCodes": ["s001"]},
        "users/SUP1": {"role": "supervisor", "assignedSalesmanCodes": ["S001"]},
        "users/SUP2": {"role": "supervisor", "assignedSalesmanCodes": ["S0011"]},
    }
    assert _holders(rows, ["S001"]) == ["user_access/sup-1", "users/SUP1"]


def test_dropping_a_long_code_removes_every_spelling_and_keeps_the_rest():
    updates = {}

    class _Recorder:
        def update(self, reference, data):
            updates[reference.path] = data["assignedSalesmanCodes"]

    holders = [
        _Snapshot("users/SUP1", {"assignedSalesmanCodes": ["sALESMAN1", "S002", "Salesman1"]}),
    ]
    InvitationService._drop_from_rosters(_Recorder(), holders, ["SALESMAN1"])
    assert updates == {"users/SUP1": ["S002"]}


def test_the_field_filter_exposes_the_parts_the_fake_reads():
    probe = firestore.FieldFilter("role", "==", "supervisor")
    assert (probe.field_path, probe.op_string, probe.value) == ("role", "==", "supervisor")
