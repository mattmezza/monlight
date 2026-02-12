"""Basic tests to verify package scaffolding and imports."""


def test_package_version():
    """Package version is defined."""
    import monlightstack

    assert monlightstack.__version__ == "0.1.0"


def test_error_client_import():
    """ErrorClient can be imported from the top-level package."""
    from monlightstack import ErrorClient

    client = ErrorClient(
        base_url="http://localhost:5010",
        api_key="test-key",
        project="test-project",
    )
    assert client.base_url == "http://localhost:5010"
    assert client.api_key == "test-key"
    assert client.project == "test-project"
    assert client.environment == "prod"


def test_metrics_client_import():
    """MetricsClient can be imported from the top-level package."""
    from monlightstack import MetricsClient

    client = MetricsClient(
        base_url="http://localhost:5012",
        api_key="test-key",
    )
    assert client.base_url == "http://localhost:5012"
    assert client.api_key == "test-key"
    assert client.flush_interval == 10.0


def test_fastapi_middleware_import():
    """MonlightMiddleware can be imported from fastapi integration."""
    from monlightstack.integrations.fastapi import MonlightMiddleware

    assert MonlightMiddleware is not None


def test_fastapi_exception_handler_import():
    """MonlightExceptionHandler can be imported from fastapi integration."""
    from monlightstack.integrations.fastapi import MonlightExceptionHandler

    assert callable(MonlightExceptionHandler)


def test_setup_monlight_import():
    """setup_monlight can be imported from fastapi integration."""
    from monlightstack.integrations.fastapi import setup_monlight

    assert callable(setup_monlight)


def test_trailing_slash_stripped():
    """Base URLs have trailing slashes stripped."""
    from monlightstack import ErrorClient, MetricsClient

    ec = ErrorClient(base_url="http://localhost:5010/", api_key="k")
    assert ec.base_url == "http://localhost:5010"

    mc = MetricsClient(base_url="http://localhost:5012/", api_key="k")
    assert mc.base_url == "http://localhost:5012"
