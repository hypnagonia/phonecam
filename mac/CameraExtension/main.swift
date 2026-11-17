import CoreMediaIO
import Foundation

// Camera extension entry point: publish the provider and keep running.
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
