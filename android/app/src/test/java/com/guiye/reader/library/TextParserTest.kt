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

    @Test fun detectsChineseAndEnglishChapters() {
        val result = TextParser.chapters(listOf("前言", "正文", "第一章 初见", "Chapter 2 Return", "尾声"))
        assertEquals(listOf(0, 2, 3, 4), result.map { it.index })
    }

    @Test fun fallsBackWhenThereIsNoChapter() {
        assertEquals(listOf(TextChapter(0, "开始阅读")), TextParser.chapters(listOf("只有正文")))
    }
}

