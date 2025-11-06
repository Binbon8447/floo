import { useState, useEffect } from 'react'
import './App.css'
import Hero from './components/Hero'
import Features from './components/Features'
import Performance from './components/Performance'
import Comparison from './components/Comparison'
import Installation from './components/Installation'
import GitHub from './components/GitHub'
import Footer from './components/Footer'

function App() {
  return (
    <div className="app">
      <Hero />
      <Features />
      <Performance />
      <Comparison />
      <Installation />
      <GitHub />
      <Footer />
    </div>
  )
}

export default App
