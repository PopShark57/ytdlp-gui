"""YouTube's JavaScript challenges, solved in JavaScriptCore by the app.

YouTube obfuscates stream URLs with "n" and signature challenges that only its own player
JavaScript can compute. yt-dlp's EJS framework solves them by running a solver script (from
the yt-dlp-ejs package) in an external JavaScript runtime such as deno or node. The app can't
launch those, but it has JavaScriptCore, so the host registers:

- a runtime named `jsc`, which reports JavaScriptCore as present without launching anything;
- a challenge provider that hands the solver script to the app as a `js.run` request, preferred
  over yt-dlp's built-in providers.
"""

from yt_dlp import globals as yt_dlp_globals
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider
from yt_dlp.utils import version_tuple
from yt_dlp.utils._jsruntime import JsRuntime, JsRuntimeInfo

from . import bridge, jobs

RUNTIME_NAME = 'jsc'

#: How long the app may take to run the solver, in seconds. Solving takes well under a second
#: on a phone; the limit only stops a runaway script.
SOLVER_TIMEOUT = 60

#: Above yt-dlp's built-in providers (deno is the highest, at 1000).
_PREFERENCE = 1100

_platform_version = None


class JavaScriptCoreRuntime(JsRuntime):
    """The `jsc` runtime: JavaScriptCore, which is part of the system and always present.

    JavaScriptCore is versioned with the operating system, so its version is the system's.
    """

    def _info(self):
        version = _platform_version or '0'
        return JsRuntimeInfo(
            name=RUNTIME_NAME, path='JavaScriptCore', version=version,
            version_tuple=version_tuple(version, lenient=True), supported=True)


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP, BuiltinIEContentProvider):
    PROVIDER_NAME = 'javascriptcore'
    JS_RUNTIME_NAME = RUNTIME_NAME

    def _run_js_runtime(self, stdin, /):
        # `stdin` is the complete program: the solver library, the solver, and a call that
        # prints the answer with console.log. The app runs it in a fresh JSContext and returns
        # what was logged.
        job = jobs.job_of(self.ie._downloader)
        if job is None:
            raise JsChallengeProviderError('JavaScriptCore can only be used inside the app')
        self.logger.debug('Running the challenge solver in JavaScriptCore')
        answer = bridge.request(job.id, {'op': 'js.run', 'script': stdin, 'timeout': SOLVER_TIMEOUT})
        if not answer.get('ok'):
            raise JsChallengeProviderError(
                f"JavaScriptCore couldn't run the challenge solver: {answer.get('error') or 'unknown error'}")
        return str(answer.get('stdout') or '')


@register_preference(JavaScriptCoreJCP)
def _preference(provider, requests):
    return _PREFERENCE


def install(platform_version):
    """Makes `jsc` an accepted value for the `js_runtimes` parameter. Called once."""
    global _platform_version
    _platform_version = platform_version
    yt_dlp_globals.supported_js_runtimes.value[RUNTIME_NAME] = JavaScriptCoreRuntime
