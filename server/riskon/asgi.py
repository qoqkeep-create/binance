"""
ASGI config for riskon project.

It exposes the ASGI callable as a module-level variable named ``application``.

For more information on this file, see
https://docs.djangoproject.com/en/4.2/howto/deployment/asgi/
"""

import os

from django.core.asgi import get_asgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'riskon.settings')

http_application = get_asgi_application()


async def application(scope, receive, send):
    if scope["type"] == "websocket":
        from market_stream.websocket import application as websocket_application
        await websocket_application(scope, receive, send)
    elif scope["type"] == "lifespan":
        while True:
            event = await receive()
            if event["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif event["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    else:
        await http_application(scope, receive, send)
