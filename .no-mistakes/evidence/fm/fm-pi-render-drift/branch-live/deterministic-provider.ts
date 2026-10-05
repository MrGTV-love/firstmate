import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { appendFileSync } from 'node:fs';
export default function (pi) {
  pi.registerProvider('branch-render-lab', {
    api: 'branch-render-lab-api', apiKey: 'local-fixture-not-a-secret', baseUrl: 'http://127.0.0.1:1',
    models: [{ id: 'deterministic', name: 'Deterministic local fixture (not an LLM)', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 10000 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const last = context.messages.at(-1);
        const toolsAlreadyRan = last?.role === 'toolResult';
        const content = toolsAlreadyRan
          ? [{ type: 'text', text: 'Branch renderer lab complete. Actual registered tools executed; the provider is a deterministic local fixture, not a live LLM.' }]
          : [{ type: 'toolCall', id: 'branch-lab-outcomes', name: 'fm_branch_outcomes', arguments: { recent: 14 } }, { type: 'toolCall', id: 'branch-lab-invalid', name: 'fm_branch_processed', arguments: { through: 0 } }, { type: 'toolCall', id: 'branch-lab-no-owner', name: 'fm_branch_processed', arguments: { through: 999 } }];
        const output = { role: 'assistant', content, api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: toolsAlreadyRan ? 'stop' : 'toolUse' };
        appendFileSync(process.env.BRANCH_LAB_PROVIDER_LOG!, JSON.stringify({ lastRole: last?.role, output }) + '\n');
        stream.push({ type: 'start', partial: output });
        content.forEach((item, contentIndex) => {
          if (item.type === 'toolCall') stream.push({ type: 'toolcall_end', contentIndex, toolCall: item, partial: output });
          else stream.push({ type: 'text_end', contentIndex, content: item.text, partial: output });
        });
        stream.push({ type: 'done', reason: output.stopReason, message: output });
        stream.end();
      });
      return stream;
    },
  });
}
