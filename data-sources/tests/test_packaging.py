import common
import openlibrary


def test_packages_are_importable_and_versioned():
    assert common.__version__
    assert openlibrary.__version__


def test_common_is_not_nested_inside_openlibrary():
    # common/ is a sibling of the sources on purpose: shared code must not
    # quietly become Open Library code that a second source works around.
    assert "openlibrary" not in common.__file__
