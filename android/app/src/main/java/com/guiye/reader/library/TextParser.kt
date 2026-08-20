package com.guiye.reader.library

data class TextChapter(val index: Int, val title: String)

object TextParser {
    fun paragraphs(text: String): List<String> {
        val values = text.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        return values.ifEmpty { listOf("文件内容为空") }
    }

    private val chapterPatterns = listOf(
        Regex("^第[0-9零〇一二三四五六七八九十百千万两]+[章节回卷部篇].{0,40}$", RegexOption.IGNORE_CASE),
        Regex("^(序章|楔子|前言|序言|后记|尾声|番外|chapter\\s+[0-9]+).{0,40}$", RegexOption.IGNORE_CASE)
    )

    fun chapters(paragraphs: List<String>): List<TextChapter> {
        val matches = paragraphs.mapIndexedNotNull { index, paragraph ->
            val title = paragraph.trim()
            if (title.length <= 60 && chapterPatterns.any { it.matches(title) }) TextChapter(index, title) else null
        }
        return matches.ifEmpty { listOf(TextChapter(0, "开始阅读")) }
    }
}

