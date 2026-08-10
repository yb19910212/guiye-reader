package com.guiye.reader.library

object TextParser {
    fun paragraphs(text: String): List<String> {
        val values = text.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        return values.ifEmpty { listOf("文件内容为空") }
    }
}
