import Foundation

/// Buffer circular de capacidade fixa. Memória sempre limitada.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity deve ser > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ element: Element) {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        for i in 0..<capacity { storage[i] = nil }
        head = 0
        count = 0
    }

    /// Remove elementos mais antigos enquanto `predicate` for verdadeiro.
    public mutating func dropOldest(while predicate: (Element) -> Bool) {
        while count > 0, let first = storage[head], predicate(first) {
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        if count == 0 { head = 0 }
    }

    public var first: Element? { count == 0 ? nil : storage[head] }
    public var last: Element? { count == 0 ? nil : storage[(head + count - 1) % capacity] }

    /// Elementos do mais antigo para o mais novo.
    public var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            if let e = storage[(head + i) % capacity] { result.append(e) }
        }
        return result
    }
}
