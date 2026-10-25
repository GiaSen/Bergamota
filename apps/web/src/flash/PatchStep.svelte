<script lang="ts">
  import { session } from "./session.svelte.ts";

  const stages = ["Extract the root and cryptexes", "Strip PAC from the shared cache", "Re-sign every Mach-O", "Build the HFS+ root", "Write the sparse image"];
</script>

<section class="sheet" aria-labelledby="patch-title">
  <h2 id="patch-title">Patching in the browser is almost here.</h2>
  <p>Renegade, the patcher, is being ported to Rust so it can run right in this page. Until it lands, build the root image with Renegade on a Mac or Linux computer, then flash it here:</p>
  <ol class="stages">
    {#each stages as s}
      <li>{s}</li>
    {/each}
  </ol>
  <pre>tools/renegade/renegade fetch-tools
tools/renegade/renegade fetch
tools/renegade/renegade root</pre>
  <p class="muted">The commands run from a checkout of the Bergamota repository; the root ends up as a <code>.simg</code> file under <code>research/</code>.</p>
  <div class="row">
    <button class="btn leaf" onclick={() => session.setPath("image")}>Flash an image I built</button>
    <a class="btn ghost" href="https://github.com/ry-diffusion/Bergamota/tree/develop/tools/renegade">Renegade's guide</a>
  </div>
</section>

<style>
  .stages { margin: 6px 0 18px; padding-left: 22px; display: grid; gap: 4px; color: var(--ink-soft); }
  pre { font: 400 14px/1.6 var(--mono); background: var(--ink); color: var(--paper); padding: 16px 18px; border-radius: 4px; overflow-x: auto; margin: 0 0 12px; }
</style>
