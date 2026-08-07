# HomeBase GUI: Agent Guidance

## Project mission

Build a SwiftUI front end for the HomeBase home-automation engine. The first supported target is iPhone/iOS, but product and architecture decisions should preserve a practical path to additional Apple platforms, especially macOS. Prefer shared SwiftUI views, models, networking code, and domain logic; isolate platform-specific behavior only where it is genuinely necessary.

## Engine relationship

The sibling repository at `../homebase` contains the home-automation engine. It already exposes a robust WebSocket API and should remain the source of truth for automation behavior, device state, and configuration. Study and use that API rather than duplicating engine responsibilities in this app.

Agents are explicitly authorized to inspect, run, and, when the GUI work truly requires it, edit `../homebase`. Keep engine changes narrowly scoped, compatible with existing consumers, and clearly separated from GUI changes. Verify both repositories when a change crosses their boundary.

## Delivery roadmap

Develop the product incrementally:

1. **Device monitoring and control**
   - Connect reliably to the engine over WebSockets.
   - Discover and present existing lights and other devices.
   - Show live device and sensor state.
   - Provide responsive controls for supported device capabilities.

2. **Automations and schedules**
   - Display existing triggers, automations, and schedules.
   - Support creating, editing, enabling, disabling, and removing them where the engine API permits.
   - Make potentially disruptive changes understandable and deliberate in the UI.

3. **Configuration and administration**
   - Expose broader engine and network configuration.
   - Support administrative workflows such as adding devices to and removing devices from the home-automation network.
   - Treat destructive, security-sensitive, and network-management actions with appropriate confirmation and error recovery.

## Engineering direction

- Treat the WebSocket protocol as an explicit client boundary. Keep transport, protocol messages, application state, and SwiftUI presentation separated enough to test independently.
- Model live state and reconnect/resynchronization behavior as core product concerns, not afterthoughts.
- Design interfaces around device capabilities so the app can grow beyond lights without accumulating device-specific conditionals throughout the UI.
- Favor accessible, native Apple-platform interactions and layouts that can adapt to different window and screen sizes.
- Add focused tests for protocol handling, state transitions, and shared domain logic as those layers are introduced.
- Preserve staged delivery: establish dependable monitoring and control before expanding into automation editing or administration.
