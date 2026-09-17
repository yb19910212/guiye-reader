package com.guiye.reader.speech

import org.junit.Assert.*
import org.junit.Test

class RemoteSpeechSettingsTest {
    @Test fun acceptsHttpsAndDoesNotDuplicateEndpoint() {
        assertEquals("https://example.org:16666/v1/audio/speech", RemoteSpeechSettings.endpoint("https://example.org:16666/"))
        assertEquals("https://example.org/v1/audio/speech", RemoteSpeechSettings.endpoint("https://example.org/v1/audio/speech"))
    }
    @Test fun refusesCleartextCredentialsAndQueryStrings() {
        listOf("http://example.org", "https://user:secret@example.org", "https://example.org?key=secret", "https://example.org#secret", "not a URL").forEach {
            assertTrue(it, runCatching { RemoteSpeechSettings.endpoint(it) }.isFailure)
        }
    }
}
