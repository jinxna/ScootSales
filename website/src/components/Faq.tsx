import faq from '../data/faq.json'
import '../styles/sales.css'

type FaqItem = {
  id: string
  topic: string
  question: string
  answer: string[]
}

const topics: string[] = faq.topics
const items: FaqItem[] = faq.items

export function Faq() {
  return (
    <section className="ss-section ss-faq ss-wrap" id="faq" aria-labelledby="faq-heading">
      <div className="ss-faq-head">
        <p className="ss-eyebrow">Questions</p>
        <h2 className="ss-title" id="faq-heading">Answered plainly.</h2>
        <p className="ss-intro">Short answers about the product, your data, plans and what happens when a payment is late.</p>
      </div>
      <div className="ss-faq-list">
        {topics.map((topic) => (
          <div className="ss-faq-group" key={topic}>
            <h3 className="ss-faq-topic">{topic}</h3>
            {items.filter((item) => item.topic === topic).map((item) => (
              <div className="ss-faq-item" key={item.id}>
                <h4 className="ss-faq-question">
                  <button
                    type="button"
                    className="ss-faq-toggle"
                    id={`faq-question-${item.id}`}
                    aria-expanded="true"
                    aria-controls={`faq-answer-${item.id}`}
                    data-faq-toggle
                  >
                    {item.question}
                  </button>
                </h4>
                <div className="ss-faq-answer" id={`faq-answer-${item.id}`}>
                  {item.answer.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
                </div>
              </div>
            ))}
          </div>
        ))}
      </div>
    </section>
  )
}
