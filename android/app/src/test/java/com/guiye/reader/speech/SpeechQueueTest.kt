package com.guiye.reader.speech

import org.junit.Assert.*
import org.junit.Test

class SpeechQueueTest {
    @Test fun chunksPreserveTextIdsAndUnicode() {
        listOf("短句。", "中文😀没有标点".repeat(600), "First sentence. Second sentence! 末尾。").forEach { text ->
            val cursor = SpeechChunkCursor(listOf(SpeechSegment(17, text, "zh-CN")), 0)
            val result = StringBuilder()
            while (true) {
                val chunk = cursor.next() ?: break
                assertEquals(17, chunk.id)
                assertTrue(chunk.text.codePointCount(0, chunk.text.length) <= 80)
                assertFalse(Character.isHighSurrogate(chunk.text.last()))
                result.append(chunk.text)
            }
            assertEquals(text, result.toString())
            assertNull(cursor.next())
        }
    }
    @Test fun sentenceAndWavIntegrity() {
        val sentence = "长".repeat(70) + "。"
        assertEquals(sentence, SpeechChunkCursor(listOf(SpeechSegment(1, sentence, "zh")), 0).next()?.text)
        val b = java.nio.ByteBuffer.allocate(48).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(40).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        b.putInt(24000).putInt(48000).putShort(2).putShort(16).put("data".toByteArray()).putInt(4).putInt(0)
        assertTrue(SpeechWAV.duration(b.array()) > 0)
        assertTrue(runCatching { SpeechWAV.duration(b.array().copyOf(47)) }.isFailure)
        assertTrue(runCatching { SpeechWAV.duration(byteArrayOf()) }.isFailure)
    }
    @Test fun emptyAndStartIndexAreSafe() {
        assertNull(SpeechChunkCursor(emptyList(), -1).next())
        val values = listOf(SpeechSegment(0, "skip", "en"), SpeechSegment(9, "read", "en"))
        assertEquals(9, SpeechChunkCursor(values, 1).next()?.id)
        assertNull(SpeechChunkCursor(values, 2).next())
        assertNull(SpeechChunkCursor(listOf(SpeechSegment(0, "   ", "en")), 0).next())
    }
    @Test fun prefetchIsBoundedAcrossTenThousandChunks() {
        val window = SpeechPrefetchWindow()
        repeat(10_000) { index ->
            while (window.canRequest) window.reserve()
            assertEquals(3, window.requested - window.played)
            assertNull(window.reserve())
            assertEquals(index, window.played)
            window.advance()
        }
    }
}
