package com.guiye.reader.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.system.measureTimeMillis

class TextParserTest {
    @Test fun parsesLargeNovelWithoutPathologicalDelay() {
        val text = buildString { repeat(30_000) { append("这是用于验证长篇 TXT 不阻塞界面的测试段落。\n") } }
        assertTrue(text.toByteArray().size > 1_000_000)
        lateinit var result: List<String>
        val elapsed = measureTimeMillis { result = TextParser.paragraphs(text) }
        assertEquals(30_000, result.size)
        assertTrue("parse took ${elapsed}ms", elapsed < 3_000)
    }
}
