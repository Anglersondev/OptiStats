import Foundation

/// Marcador de encerramento definido pelos handlers de SIGTERM/SIGINT. Só é escrito/lido como inteiro simples.
var terminateRequested: Int32 = 0

func installTerminationHandlers() {
    terminateRequested = 0   // força a inicialização do global antes de qualquer sinal
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM) { _ in terminateRequested = 1 }
    signal(SIGINT) { _ in terminateRequested = 1 }
}
