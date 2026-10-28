import Testing
import Vapor
@testable import PostgresNIO

@Suite("PostgreSQL read-completion recovery")
struct PostgresReadCompletionTests {
    private func row(_ value: Int32) -> DataRow {
        var bytes = ByteBuffer()
        bytes.writeInteger(Int32(4))
        bytes.writeInteger(value)
        return DataRow(columnCount: 1, bytes: bytes)
    }

    @Test("Repeated completion without demand does not terminate the server")
    func repeatedEmptyCompletion() {
        var stream = RowStreamStateMachine()
        #expect(stream.channelReadComplete() == nil)
        #expect(stream.channelReadComplete() == nil)
        _ = stream.read()
        let expected = row(1)
        stream.receivedRow(expected)
        #expect(stream.channelReadComplete() == [expected])
    }

    @Test("Buffered rows survive unsolicited completion in all waiting states")
    func bufferedRowsAreNotLost() {
        for waitingState in 0..<3 {
            var stream = RowStreamStateMachine()
            let first = row(1), second = row(2)
            if waitingState == 0 {
                #expect(stream.channelReadComplete() == nil)
            } else {
                stream.receivedRow(first)
                #expect(stream.channelReadComplete() == [first])
                if waitingState == 2 { _ = stream.read() }
            }
            stream.receivedRow(second)
            #expect(stream.channelReadComplete() == nil)
            #expect(stream.channelReadComplete() == nil)
            #expect(stream.end() == [second])
        }
    }

    @Test("Demand resumes without duplicate rows after unsolicited completion")
    func demandResumes() {
        var stream = RowStreamStateMachine()
        let first = row(1), second = row(2)
        stream.receivedRow(first)
        #expect(stream.channelReadComplete() == [first])
        _ = stream.read()
        stream.receivedRow(second)
        #expect(stream.channelReadComplete() == nil)
        _ = stream.demandMoreResponseBodyParts()
        #expect(stream.channelReadComplete() == [second])
        #expect(stream.end().isEmpty)
    }
}
