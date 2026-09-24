const express = require('express');
const app = express();
app.use(express.json());

// TODO: Integrate AWS SDK for SQS
app.post('/jobs', (req, res) => {
    // 1. Receive HTTP request
    // 2. Create job
    // 3. Send message to SQS
    // 4. Return response to client
    res.status(202).json({ message: "Job accepted", jobId: Date.now() });
});

const port = process.env.PORT || 8080;
app.listen(port, () => {
    console.log(`API Service listening on port ${port}`);
});
