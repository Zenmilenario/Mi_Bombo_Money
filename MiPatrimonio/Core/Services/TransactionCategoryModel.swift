import Foundation

/// A regularized softmax classifier trained on weighted text examples.
struct TransactionCategoryModel: Sendable {
    struct Example: Sendable, Equatable {
        let text: String
        let categoryID: UUID
        let weight: Double
    }

    struct Prediction: Sendable {
        let categoryID: UUID
        let score: Double
    }

    private let labels: [UUID]
    private let weights: [String: [Double]]

    static func tokens(_ text: String) -> [String] {
        text.prefix(240)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .prefix(18)
            .filter { $0.count >= 2 }
            .map(String.init)
    }

    private static func features(_ text: String) -> [String] {
        var result = Set<String>()
        for word in tokens(text) {
            result.insert("w:" + word)
            let letters = Array("^" + String(word.prefix(24)) + "$")
            for index in 0..<(letters.count - 2) {
                result.insert("c:" + String(letters[index...index + 2]))
            }
        }
        return result.sorted()
    }

    static func train(_ examples: [Example]) -> Self? {
        let labels = Array(Set(examples.map(\.categoryID))).sorted { $0.uuidString < $1.uuidString }
        guard labels.count >= 2 else { return nil }
        let indices = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let rows = examples.compactMap { example -> ([String], Int, Double)? in
            let features = features(example.text)
            guard !features.isEmpty, let label = indices[example.categoryID] else { return nil }
            return (features, label, example.weight)
        }
        guard Set(rows.map { $0.1 }).count >= 2 else { return nil }
        let zero = [Double](repeating: 0, count: labels.count)
        var weights: [String: [Double]] = [:]
        for epoch in 0..<18 {
            if Task.isCancelled { return nil }
            let step = 0.24 / (1 + Double(epoch) * 0.12)
            // Rotate the starting point to reduce sensitivity to example order.
            for offset in rows.indices {
                let (features, label, weight) = rows[(offset + epoch * 13) % rows.count]
                let scale = 1 / sqrt(Double(features.count))
                var scores = zero
                for feature in features {
                    guard let vector = weights[feature] else { continue }
                    for index in labels.indices { scores[index] += vector[index] * scale }
                }
                let probabilities = softmax(scores)
                let gradient = labels.indices.map { index in
                    step * weight * scale * ((index == label ? 1.0 : 0.0) - probabilities[index])
                }
                for feature in features {
                    var vector = weights[feature] ?? zero
                    for index in labels.indices {
                        vector[index] = vector[index] * 0.9995 + gradient[index]
                    }
                    weights[feature] = vector
                }
            }
        }
        return Self(labels: labels, weights: weights)
    }

    func predict(_ text: String, allowed: Set<UUID>) -> Prediction? {
        let features = Self.features(text)
        let known = features.compactMap { weights[$0] }
        let candidates = labels.indices.filter { allowed.contains(labels[$0]) }
        guard candidates.count >= 2, known.count >= 4,
              known.count * 3 >= features.count else { return nil }
        let scale = 1 / sqrt(Double(features.count))
        let scores = candidates.map { index in known.reduce(0.0) { $0 + $1[index] * scale } }
        let probabilities = Self.softmax(scores)
        let ranked = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
        let best = ranked[0], second = ranked[1]
        // This gate controls which proposals are useful enough to show.
        guard probabilities[best] >= 0.30, probabilities[best] - probabilities[second] >= 0.10 else { return nil }
        return Prediction(categoryID: labels[candidates[best]], score: probabilities[best])
    }

    private static func softmax(_ scores: [Double]) -> [Double] {
        let maximum = scores.max() ?? 0
        let values = scores.map { exp($0 - maximum) }
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }

    /// Invented descriptions grouped by the app's starter category catalog.
    static let syntheticExamples: [(String, [String])] = [
        ("Supermercado", ["Supermercado La Cesta compra", "Mercado Fresco alimentación", "Hipermercado Plaza compra semanal", "Tienda de alimentos Fruta Verde"]),
        ("Restaurantes", ["Restaurante El Olivo cena", "Cafetería Nube desayuno", "Bar Terraza menú", "Pizzería Farol comida"]),
        ("Transporte", ["Metro billete urbano", "Taxi trayecto ciudad", "Autobús recarga abono", "Tren cercanías billete", "Viaje VTC traslado urbano"]),
        ("Coche", ["Gasolinera Ruta combustible", "Taller mecánico revisión coche", "Estacionamiento parking vehículo", "Peaje autopista"]),
        ("Vivienda", ["Alquiler mensual vivienda", "Recibo comunidad vecinos", "Cuota hipoteca vivienda", "Arrendamiento piso"]),
        ("Salud", ["Clínica consulta médica", "Dentista revisión dental", "Fisioterapia sesión", "Centro óptico graduación"]),
        ("Farmacia", ["Farmacia Plaza medicamentos", "Parafarmacia Sol", "Farmacia Avenida receta", "Farmacia Norte productos"]),
        ("Educación", ["Universidad matrícula curso", "Academia clases idiomas", "Formación curso profesional", "Cuota escuela estudios"]),
        ("Servicios del hogar", ["Recibo suministro eléctrico", "Factura gas vivienda", "Recibo agua municipal", "Electricidad factura mensual"]),
        ("Internet y móvil", ["Factura fibra internet", "Operador telefonía móvil", "Banda ancha cuota conexión", "Recarga teléfono móvil"]),
        ("Seguros", ["Póliza seguro hogar", "Prima seguro vehículo", "Recibo aseguradora", "Cuota seguro salud"]),
        ("Suscripciones", ["Suscripción streaming mensual", "Cuota plataforma música", "Renovación membresía digital", "Suscripción revista"]),
        ("Compras", ["Tienda electrónica auriculares", "Compra online accesorios", "Bazar artículos hogar", "Pedido comercio general"]),
        ("Ropa", ["Tienda moda prendas", "Zapatería calzado", "Compra ropa abrigo", "Tienda textil camisetas"]),
        ("Ocio", ["Cine entradas película", "Entrada concierto música", "Teatro espectáculo", "Compra videojuego"]),
        ("Viajes", ["Hotel reserva alojamiento", "Billete vuelo aerolínea", "Hostal estancia", "Agencia viaje reserva"]),
        ("Mascotas", ["Veterinario consulta mascota", "Alimento perro tienda animales", "Arena gato tienda mascotas", "Peluquería canina"]),
        ("Impuestos y comisiones", ["Comisión mantenimiento cuenta", "Impuesto municipal recibo", "Comisión bancaria tarjeta", "Tasa administración"]),
        ("Nómina", ["Abono nómina mensual", "Ingreso salario empresa", "Transferencia haberes nómina", "Pago mensual sueldo"]),
        ("Reembolsos", ["Devolución compra comercio", "Reembolso pedido devuelto", "Abono devolución tarjeta", "Devolución importe compra"]),
        ("Intereses", ["Abono intereses cuenta", "Liquidación intereses ahorro", "Interés remuneración saldo", "Intereses depósito"]),
        ("Dividendos", ["Abono dividendo acciones", "Dividendo cartera valores", "Pago dividendos participaciones", "Distribución dividendos"]),
        ("Ventas", ["Ingreso venta segunda mano", "Cobro venta artículo", "Abono venta marketplace", "Liquidación ventas"])
    ]
}
