// RamBar — indicador mínimo de RAM para la barra de menús de macOS.
// Sin dependencias: AppKit + APIs de Mach. Se compila con ./build.sh
//
// Qué hace: lee los contadores que el kernel ya mantiene y los pinta en la
// barra. No toca procesos, no escribe nada, no abre red.

import AppKit
import ServiceManagement

// MARK: - Configuración

/// Qué se muestra en la barra.
enum Display {
    case percent     // 61%
    case gigabytes   // 9.8/16 GB
    case both        // 61% · 9.8 GB
}

private enum Config {
    /// Cada cuántos segundos se refresca el indicador.
    static let refreshInterval: TimeInterval = 3
    /// Qué se muestra en la barra.
    static let display: Display = .gigabytes
    /// A partir de esta fracción de uso, el texto se pone en rojo.
    static let warningFraction = 0.90
    /// Cuántos procesos listar en el menú (0 desactiva la sección).
    static let topProcessCount = 5
    /// Símbolo SF junto al número. nil lo quita; "cpu" o
    /// "memorychip.fill" son alternativas razonables.
    static let symbolName: String? = "memorychip"
    /// Tamaño de la fuente del indicador.
    static let fontSize: CGFloat = 12
}

// MARK: - Lectura de memoria

/// Presión de memoria: lo que mide la gráfica del Monitor de Actividad.
/// Responde "al sistema le está costando", que no es lo mismo que
/// "cuánta memoria está ocupada".
enum MemoryPressure: Int32 {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "alta"
        case .critical: return "crítica"
        }
    }

    /// nil en presión normal: sin color explícito, AppKit pinta el icono
    /// y el texto como el resto de la barra y los invierte solo cuando el
    /// item está resaltado. Solo se fuerza un color cuando hay algo que avisar.
    var color: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

struct MemorySample {
    let used: Int64
    let total: Int64
    let wired: Int64
    let compressed: Int64
    let cached: Int64
    let pressure: MemoryPressure?
    let swapUsed: Int64
    let swapTotal: Int64

    var fraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

final class MemoryReader {
    private let pageSize: Int64
    private let totalBytes: Int64

    init() {
        var rawPageSize: vm_size_t = 4096
        host_page_size(mach_host_self(), &rawPageSize)
        pageSize = Int64(rawPageSize)

        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        totalBytes = sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 ? Int64(memsize) : 0
    }

    func read() -> MemorySample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // Mismo criterio que el Monitor de Actividad:
        // "Memoria usada" = memoria de apps + conectada (wired) + comprimida.
        let purgeable = Int64(stats.purgeable_count) * pageSize
        let appMemory = max(0, Int64(stats.internal_page_count) * pageSize - purgeable)
        let wired = Int64(stats.wire_count) * pageSize
        let compressed = Int64(stats.compressor_page_count) * pageSize
        let cached = Int64(stats.external_page_count) * pageSize + purgeable

        let swap = readSwap()

        return MemorySample(
            used: appMemory + wired + compressed,
            total: totalBytes,
            wired: wired,
            compressed: compressed,
            cached: cached,
            pressure: readPressure(),
            swapUsed: swap.used,
            swapTotal: swap.total
        )
    }

    private func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return nil }

        return MemoryPressure(rawValue: level)
    }

    /// vm.swapusage devuelve una struct xsw_usage: tres UInt64 (total,
    /// disponible, usado) y dos campos de 32 bits al final. Se lee como
    /// buffer crudo para no depender de cómo quede expuesta la struct.
    private func readSwap() -> (used: Int64, total: Int64) {
        var raw = [UInt64](repeating: 0, count: 4)
        var size = raw.count * MemoryLayout<UInt64>.stride
        guard sysctlbyname("vm.swapusage", &raw, &size, nil, 0) == 0 else { return (0, 0) }

        return (used: Int64(raw[2]), total: Int64(raw[0]))
    }
}

// MARK: - Procesos

struct ProcessUsage {
    let name: String
    let bytes: Int64
}

enum ProcessLister {
    /// Procesos que más memoria residente consumen, agrupados por nombre:
    /// Chrome y compañía se reparten en decenas de helpers, y verlos
    /// sumados es lo único que responde "quién se está comiendo la RAM".
    /// Solo se consulta al abrir el menú, no en cada refresco.
    static func top(_ count: Int) -> [ProcessUsage] {
        guard count > 0, let output = run("/bin/ps", ["-axo", "rss=,comm="]) else { return [] }

        var totals: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let kilobytes = Int64(trimmed[trimmed.startIndex..<space]) else { continue }

            let path = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let name = String(path.split(separator: "/").last ?? "")
            guard !name.isEmpty else { continue }

            totals[name, default: 0] += kilobytes * 1024
        }

        return totals
            .sorted { $0.value > $1.value }
            .prefix(count)
            .map { ProcessUsage(name: $0.key, bytes: $0.value) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        // Leer antes de esperar: al revés, un volcado grande llena el pipe
        // y el proceso se queda bloqueado para siempre.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reader = MemoryReader()
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let usedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let breakdownItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pressureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let processHeader = NSMenuItem(title: "Procesos", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(
        title: "Abrir al iniciar sesión",
        action: nil,
        keyEquivalent: ""
    )
    private var processItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setUpIcon()

        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        // En .common el timer sigue disparando con el menú abierto.
        let timer = Timer(timeInterval: Config.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = Config.refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Un símbolo SF evita empaquetar imágenes: viene con el sistema y,
    /// marcado como template, se adapta solo a la barra clara y a la oscura.
    /// Si el símbolo no existiera, el inicializador devuelve nil y la app
    /// simplemente se queda sin icono.
    private func setUpIcon() {
        guard let name = Config.symbolName,
              let button = statusItem.button,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Memoria")
        else { return }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: Config.fontSize,
            weight: .regular
        )
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        image.isTemplate = true

        button.image = image
        button.imagePosition = .imageLeading
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        usedItem.isEnabled = false
        breakdownItem.isEnabled = false
        pressureItem.isEnabled = false
        menu.addItem(usedItem)
        menu.addItem(breakdownItem)
        menu.addItem(pressureItem)
        menu.addItem(.separator())

        if Config.topProcessCount > 0 {
            processHeader.isEnabled = false
            menu.addItem(processHeader)

            for _ in 0..<Config.topProcessCount {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.indentationLevel = 1
                processItems.append(item)
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        let activity = NSMenuItem(
            title: "Abrir Monitor de Actividad",
            action: #selector(openActivityMonitor),
            keyEquivalent: ""
        )
        activity.target = self
        menu.addItem(activity)

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        refreshLaunchAtLogin()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Salir",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return menu
    }

    private func refresh() {
        guard let button = statusItem.button else { return }

        guard let sample = reader.read() else {
            button.title = "RAM —"
            return
        }

        let percent = Int((sample.fraction * 100).rounded())
        let title: String
        switch Config.display {
        case .percent:
            title = "\(percent)%"
        case .gigabytes:
            title = Self.formatCompact(used: sample.used, total: sample.total)
        case .both:
            title = "\(percent)% · \(Self.format(sample.used))"
        }
        // La presión manda: estar al 95% con presión normal no es un
        // problema. El umbral de Config solo entra si el sysctl falla.
        let color: NSColor?
        switch sample.pressure {
        case .some(let pressure):
            color = pressure.color
        case .none:
            color = sample.fraction >= Config.warningFraction ? .systemRed : nil
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Config.fontSize, weight: .regular),
        ]
        if let color = color {
            attributes[.foregroundColor] = color
        }

        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        // El tinte es lo que arrastra al icono al mismo color que el texto.
        // nil devuelve el control a AppKit.
        button.contentTintColor = color

        usedItem.title = "\(Self.format(sample.used)) de \(Self.format(sample.total)) · \(percent)%"
        breakdownItem.title = "Conectada \(Self.format(sample.wired))  ·  "
            + "Comprimida \(Self.format(sample.compressed))  ·  "
            + "Caché \(Self.format(sample.cached))"

        let pressureText = sample.pressure.map { "Presión \($0.label)" } ?? "Presión no disponible"
        let swapText = sample.swapUsed > 0
            ? "Swap \(Self.format(sample.swapUsed)) de \(Self.format(sample.swapTotal))"
            : "Sin swap en uso"
        pressureItem.title = "\(pressureText)  ·  \(swapText)"
    }

    /// SMAppService es la forma que macOS 13 dejó para esto: registra la
    /// propia app como ítem de inicio, sin helpers ni launch agents a mano.
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            reportLaunchAtLoginFailure(error)
        }

        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.state = .on
        case .requiresApproval:
            // Registrada, pero el usuario tiene que aprobarla en Ajustes.
            launchAtLoginItem.state = .mixed
        default:
            launchAtLoginItem.state = .off
        }
    }

    private func reportLaunchAtLoginFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo cambiar el arranque automático"
        alert.informativeText = """
        \(error.localizedDescription)

        Suele deberse a que la app no está en la carpeta Aplicaciones. \
        Cópiala ahí y vuelve a intentarlo.
        """

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    private static func gigabytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_073_741_824
    }

    private static func format(_ bytes: Int64) -> String {
        String(format: "%.1f GB", gigabytes(bytes))
    }

    /// "9.8/16 GB" — compacto para la barra.
    private static func formatCompact(used: Int64, total: Int64) -> String {
        String(format: "%.1f/%.0f GB", gigabytes(used), gigabytes(total))
    }

    private func refreshProcesses() {
        guard !processItems.isEmpty else { return }

        let top = ProcessLister.top(processItems.count)
        processHeader.isHidden = top.isEmpty

        for (index, item) in processItems.enumerated() {
            guard index < top.count else {
                item.isHidden = true
                continue
            }

            let process = top[index]
            item.title = "\(process.name) — \(Self.format(process.bytes))"
            item.isHidden = false
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        refreshProcesses()
        // Por si se cambió desde Ajustes del Sistema mientras tanto.
        refreshLaunchAtLogin()
    }
}

// MARK: - Entrada

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // sin icono en el Dock
app.run()
