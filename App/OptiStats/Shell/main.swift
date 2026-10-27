import Cocoa

// Ponto de entrada manual: aplicativo de barra de menus (LSUIElement), sem Dock e sem janela principal.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
